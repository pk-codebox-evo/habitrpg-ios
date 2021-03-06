//
//  HRPGManager.m
//  HabitRPG
//
//  Created by Phillip Thelen on 09/03/14.
//  Copyright (c) 2014 Phillip Thelen. All rights reserved.
//

#import "HRPGManager.h"
#import <Crashlytics/Crashlytics.h>
#import "CRToast.h"
#import "HRPGTaskResponse.h"
#import "HRPGLoginData.h"
#import <Google/Analytics.h>
#import <NIKFontAwesomeIconFactory.h>
#import <PDKeychainBindings.h>
#import "Gear.h"
#import <YYWebImage.h>
#import "Amplitude.h"
#import "HRPGEmptySerializer.h"
#import "CRToast.h"
#import "Customization.h"
#import "Gear.h"
#import "HRPGAppDelegate.h"
#import "HRPGContentResponse.h"
#import "HRPGDeathView.h"
#import "HRPGEmptySerializer.h"
#import "HRPGImageOverlayView.h"
#import "HRPGLoginData.h"
#import "UIColor+Habitica.h"
#import "HRPGNetworkIndicatorController.h"
#import <Crashlytics/Crashlytics.h>
#import "HRPGSharingManager.h"
#import "HRPGTaskResponse.h"
#import "UIView+Screenshot.h"
#import "HRPGUserBuyResponse.h"
#import "Quest.h"
#import "Reward.h"
#import "ChecklistItem.h"
#import "UIColor+Habitica.h"
#import "HRPGURLParser.h"
#import "HRPGResponseMessage.h"
#import "NSString+StripHTML.h"
#import "PushDevice.h"
#import "Shop.h"

@interface HRPGManager ()
@property(nonatomic) NIKFontAwesomeIconFactory *iconFactory;
@property HRPGNetworkIndicatorController *networkIndicatorController;
@end

@implementation HRPGManager {
}
@synthesize managedObjectContext;
RKManagedObjectStore *managedObjectStore;
NSUserDefaults *defaults;
NSString *currentUser;

+ (RKValueTransformer *)millisecondsSince1970ToDateValueTransformer {
    return [RKBlockValueTransformer
        valueTransformerWithValidationBlock:^BOOL(__unsafe_unretained Class sourceClass,
                                                  __unsafe_unretained Class destinationClass) {
            return [sourceClass isSubclassOfClass:[NSNumber class]] &&
                   [destinationClass isSubclassOfClass:[NSDate class]];
        }
        transformationBlock:^BOOL(id inputValue, __autoreleasing id *outputValue,
                                  __unsafe_unretained Class outputValueClass,
                                  NSError *__autoreleasing *error) {
            RKValueTransformerTestInputValueIsKindOfClass(inputValue, (@[ [NSNumber class] ]),
                                                          error);
            RKValueTransformerTestOutputValueClassIsSubclassOfClass(outputValueClass,
                                                                    (@[ [NSDate class] ]), error);
            *outputValue =
                [NSDate dateWithTimeIntervalSince1970:([inputValue longLongValue] / 1000)];
            return YES;
        }];
}

- (void)loadObjectManager:(RKManagedObjectStore *)existingManagedObjectStore {
    NSError *error = nil;
    NSURL *modelURL =
        [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"HabitRPG" ofType:@"momd"]];
    // NOTE: Due to an iOS 5 bug, the managed object model returned is immutable.
    if (!existingManagedObjectStore) {
        NSManagedObjectModel *managedObjectModel =
            [[[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL] mutableCopy];
        managedObjectStore =
            [[RKManagedObjectStore alloc] initWithManagedObjectModel:managedObjectModel];

        // Initialize the Core Data stack
        [managedObjectStore createPersistentStoreCoordinator];

        NSString *storePath =
            [RKApplicationDataDirectory() stringByAppendingPathComponent:@"HabitRPG.sqlite"];
        NSDictionary *options = @{
            NSMigratePersistentStoresAutomaticallyOption : @YES,
            NSInferMappingModelAutomaticallyOption : @YES
        };
        NSPersistentStore *persistentStore =
            [managedObjectStore addSQLitePersistentStoreAtPath:storePath
                                        fromSeedDatabaseAtPath:nil
                                             withConfiguration:nil
                                                       options:options
                                                         error:&error];

        NSAssert(persistentStore, @"Failed to add persistent store with error: %@", error);

        // Create the managed object contexts
        [managedObjectStore createManagedObjectContexts];
    } else {
        managedObjectStore = existingManagedObjectStore;
    }

    // Configure a managed object cache to ensure we do not create duplicate objects
    managedObjectStore.managedObjectCache = [[RKInMemoryManagedObjectCache alloc]
        initWithManagedObjectContext:managedObjectStore.persistentStoreManagedObjectContext];

    NSString *ROOT_URL = nil;

#ifdef DEBUG
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *CUSTOM_DOMAIN = info[@"CustomDomain"];
    NSString *DISABLE_SSL = info[@"DisableSSL"];

    if (CUSTOM_DOMAIN.length == 0) {
        CUSTOM_DOMAIN = @"localhost:3000/";
    }

    if ([DISABLE_SSL isEqualToString:@"true"]) {
        ROOT_URL = [NSString stringWithFormat:@"http://%@", CUSTOM_DOMAIN];
    } else {
        ROOT_URL = [NSString stringWithFormat:@"http://%@", CUSTOM_DOMAIN];
    }
#else
    ROOT_URL = @"https://habitica.com/";
#endif

    ROOT_URL = [ROOT_URL stringByAppendingString:@"api/v3/"];

    
    
    // Set the default store shared instance
    [RKManagedObjectStore setDefaultStore:managedObjectStore];
    RKObjectManager *objectManager =
        [RKObjectManager managerWithBaseURL:[NSURL URLWithString:ROOT_URL]];
    objectManager.managedObjectStore = managedObjectStore;

    [RKObjectManager setSharedManager:objectManager];
    [RKObjectManager sharedManager].requestSerializationMIMEType = RKMIMETypeJSON;
    [objectManager.HTTPClient setReachabilityStatusChangeBlock:^(
                                  AFNetworkReachabilityStatus status) {
        if (status == AFNetworkReachabilityStatusUnknown) {
            return;
        }
        if (status == AFNetworkReachabilityStatusNotReachable) {
            UIAlertView *alertView = [[UIAlertView alloc]
                    initWithTitle:NSLocalizedString(@"Connection Error", nil)
                          message:NSLocalizedString(@"There is no internet connection. You will "
                                                    @"not be able to perform any actions.",
                                                    nil)
                         delegate:self
                cancelButtonTitle:NSLocalizedString(@"OK", nil)
                otherButtonTitles:nil, nil];

            [alertView show];
        }
    }];

    RKValueTransformer *transformer = [HRPGManager millisecondsSince1970ToDateValueTransformer];
    [[RKValueTransformer defaultValueTransformer] insertValueTransformer:transformer atIndex:0];

    RKEntityMapping *taskMapping =
        [RKEntityMapping mappingForEntityForName:@"Task" inManagedObjectStore:managedObjectStore];
    [taskMapping addAttributeMappingsFromDictionary:@{
        @"_id" : @"id",
        @"attribute" : @"attribute",
        @"down" : @"down",
        @"up" : @"up",
        @"priority" : @"priority",
        @"text" : @"text",
        @"value" : @"value",
        @"type" : @"type",
        @"completed" : @"completed",
        @"notes" : @"notes",
        @"streak" : @"streak",
        @"dateCreated" : @"dateCreated",
        @"repeat.m" : @"monday",
        @"repeat.t" : @"tuesday",
        @"repeat.w" : @"wednesday",
        @"repeat.th" : @"thursday",
        @"repeat.f" : @"friday",
        @"repeat.s" : @"saturday",
        @"repeat.su" : @"sunday",
        @"date" : @"duedate",
        @"tags" : @"tagArray",
        @"everyX" : @"everyX",
        @"frequency" : @"frequency",
        @"startDate" : @"startDate",
        @"challenge.id" : @"challengeID"
    }];
    taskMapping.identificationAttributes = @[ @"id" ];
    RKEntityMapping *checklistItemMapping =
        [RKEntityMapping mappingForEntityForName:@"ChecklistItem"
                            inManagedObjectStore:managedObjectStore];
    [checklistItemMapping addAttributeMappingsFromArray:@[ @"id", @"text", @"completed" ]];
    checklistItemMapping.identificationAttributes = @[ @"id", @"text" ];

    [taskMapping addPropertyMapping:[RKRelationshipMapping
                                        relationshipMappingFromKeyPath:@"checklist"
                                                             toKeyPath:@"checklist"
                                                           withMapping:checklistItemMapping]];
    RKEntityMapping *remindersMapping =
        [RKEntityMapping mappingForEntityForName:@"Reminder"
                            inManagedObjectStore:managedObjectStore];
    [remindersMapping addAttributeMappingsFromArray:@[ @"id", @"startDate", @"time" ]];
    remindersMapping.identificationAttributes = @[ @"id" ];

    [taskMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"reminders"
                                                                       toKeyPath:@"reminders"
                                                                     withMapping:remindersMapping]];

    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Task class]
                             pathPattern:@"tasks/:id"
                                  method:RKRequestMethodGET]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Task class]
                             pathPattern:@"tasks/:id"
                                  method:RKRequestMethodPUT]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Task class]
                             pathPattern:@"tasks/user"
                                  method:RKRequestMethodPOST]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Task class]
                             pathPattern:@"tasks/:id"
                                  method:RKRequestMethodDELETE]];

    RKObjectMapping *taskRequestMapping =
        [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [taskRequestMapping addAttributeMappingsFromDictionary:@{
        @"id" : @"_id",
        @"attribute" : @"attribute",
        @"down" : @"down",
        @"up" : @"up",
        @"priority" : @"priority",
        @"text" : @"text",
        @"value" : @"value",
        @"type" : @"type",
        @"completed" : @"completed",
        @"notes" : @"notes",
        @"streak" : @"streak",
        @"dateCreated" : @"dateCreated",
        @"monday" : @"repeat.m",
        @"tuesday" : @"repeat.t",
        @"wednesday" : @"repeat.w",
        @"thursday" : @"repeat.th",
        @"friday" : @"repeat.f",
        @"saturday" : @"repeat.s",
        @"sunday" : @"repeat.su",
        @"duedate" : @"date",
        @"tagArray" : @"tags",
        @"everyX" : @"everyX",
        @"frequency" : @"frequency",
        @"startDate" : @"startDate"
    }];
    RKObjectMapping *checklistItemRequestMapping =
        [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [checklistItemRequestMapping addAttributeMappingsFromArray:@[ @"id", @"text", @"completed" ]];
    [taskRequestMapping
        addPropertyMapping:[RKRelationshipMapping
                               relationshipMappingFromKeyPath:@"checklist"
                                                    toKeyPath:@"checklist"
                                                  withMapping:checklistItemRequestMapping]];
    RKObjectMapping *reminderRequestmapping =
        [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [reminderRequestmapping addAttributeMappingsFromArray:@[ @"id", @"startDate", @"time" ]];
    [taskRequestMapping
        addPropertyMapping:[RKRelationshipMapping
                               relationshipMappingFromKeyPath:@"reminders"
                                                    toKeyPath:@"reminders"
                                                  withMapping:reminderRequestmapping]];

    RKResponseDescriptor *responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:taskMapping
                               method:RKRequestMethodPUT
                          pathPattern:@"tasks/:id"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:taskMapping
                               method:RKRequestMethodDELETE
                          pathPattern:@"tasks/:id"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    RKRequestDescriptor *requestDescriptor =
        [RKRequestDescriptor requestDescriptorWithMapping:taskRequestMapping
                                              objectClass:[Task class]
                                              rootKeyPath:nil
                                                   method:RKRequestMethodPUT];
    [objectManager addRequestDescriptor:requestDescriptor];

    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithName:@"taskdirection"
                            pathPattern:@"tasks/:id/score/:direction"
                                 method:RKRequestMethodPOST]];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:taskMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"tasks/user"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    requestDescriptor = [RKRequestDescriptor requestDescriptorWithMapping:taskRequestMapping
                                                              objectClass:[Task class]
                                                              rootKeyPath:nil
                                                                   method:RKRequestMethodPOST];
    [objectManager addResponseDescriptor:responseDescriptor];
    [objectManager addRequestDescriptor:requestDescriptor];

    RKEntityMapping *rewardMapping =
        [RKEntityMapping mappingForEntityForName:@"Reward" inManagedObjectStore:managedObjectStore];
    [rewardMapping addAttributeMappingsFromDictionary:@{
        @"_id" : @"key",
        @"text" : @"text",
        @"dateCreated" : @"dateCreated",
        @"value" : @"value",
        @"type" : @"type",
        @"notes" : @"notes",
        @"@metadata.mapping.collectionIndex" : @"order",
        @"tags" : @"tagArray"
    }];
    rewardMapping.identificationAttributes = @[ @"key" ];

    RKObjectMapping *rewardRequestMapping =
        [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [rewardRequestMapping addAttributeMappingsFromDictionary:@{
        @"key" : @"_id",
        @"text" : @"text",
        @"value" : @"value",
        @"notes" : @"notes",
        @"type" : @"type",
        @"tagArray" : @"tags"
    }];

    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Reward class]
                             pathPattern:@"tasks/:key"
                                  method:RKRequestMethodGET]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Reward class]
                             pathPattern:@"tasks/:key"
                                  method:RKRequestMethodPUT]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Reward class]
                             pathPattern:@"tasks/user"
                                  method:RKRequestMethodPOST]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Reward class]
                             pathPattern:@"tasks/:key"
                                  method:RKRequestMethodDELETE]];

    requestDescriptor = [RKRequestDescriptor requestDescriptorWithMapping:rewardRequestMapping
                                                              objectClass:[Reward class]
                                                              rootKeyPath:nil
                                                                   method:RKRequestMethodPOST];
    [objectManager addRequestDescriptor:requestDescriptor];
    requestDescriptor = [RKRequestDescriptor requestDescriptorWithMapping:rewardRequestMapping
                                                              objectClass:[Reward class]
                                                              rootKeyPath:nil
                                                                   method:RKRequestMethodPUT];
    [objectManager addRequestDescriptor:requestDescriptor];

    RKDynamicMapping *dynamicTaskMapping = [RKDynamicMapping new];
    [dynamicTaskMapping
        setObjectMappingForRepresentationBlock:^RKObjectMapping *(id representation) {
            if ([[representation valueForKey:@"type"] isEqualToString:@"reward"]) {
                return rewardMapping;
            } else {
                return taskMapping;
            }
        }];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:dynamicTaskMapping
                               method:RKRequestMethodGET
                          pathPattern:@"tasks/user"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:dynamicTaskMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"tasks/clearCompletedTodos"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    
    responseDescriptor = [RKResponseDescriptor
                          responseDescriptorWithMapping:taskMapping
                          method:RKRequestMethodPOST
                          pathPattern:@"tasks/:id/checklist/:checklistId/score"
                          keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher =
            [RKPathMatcher pathMatcherWithPattern:@"tasks/clearCompletedTodos"];

        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:NO
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Task"];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"type=='todo'"];
            return fetchRequest;
        }

        return nil;
    }];
    
    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher =
        [RKPathMatcher pathMatcherWithPattern:@"content"];
        
        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:NO
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Customization"];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"type=='background'"];
            return fetchRequest;
        }
        
        return nil;
    }];

    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"tasks/user"];

        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:NO
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Task"];
            
            HRPGURLParser *parser = [[HRPGURLParser alloc] initWithURLString:[URL absoluteString]];
            NSString *typeQuery = [parser valueForVariable:@"type"];
            if (typeQuery) {
                if ([typeQuery isEqualToString:@"habits"]) {
                    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"type == 'habit'"]];
                }else if ([typeQuery isEqualToString:@"dailies"]) {
                    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"type == 'daily'"]];
                } else if ([typeQuery isEqualToString:@"todos"]) {
                    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"type == 'todo' && completed == NO"]];
                } else if ([typeQuery isEqualToString:@"completedTodos"]) {
                    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"type == 'todo' && completed == YES"]];
                }
            } else {
                [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"(type == 'todo' && completed == NO) || type != 'todo'"]];
            }
            return fetchRequest;
        }

        return nil;
    }];

    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"tasks/user"];

        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:NO
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Reward"];
            return fetchRequest;
        }

        return nil;
    }];

    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"user"];

        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:NO
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Tag"];
            return fetchRequest;
        }

        return nil;
    }];

    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"groups"];

        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:YES
                              parsedArguments:&argsDict];
        if (match) {
            if ([URL.query isEqualToString:@"type=guilds"]) {
                NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Group"];
                fetchRequest.predicate =
                    [NSPredicate predicateWithFormat:@"type=='guild' && isMember == true"];
                return fetchRequest;
            }
        }

        return nil;
    }];
    
    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"groups/:id/members"];
        
        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:YES
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"User"];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"partyID == %@", argsDict[@"id"]];
            return fetchRequest;
        }
        
        return nil;
    }];
    
    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"shops/:identifier"];
        
        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:YES
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"ShopItem"];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"category.shop.identifier == %@", argsDict[@"identifier"]];
            return fetchRequest;
        }
        
        return nil;
    }];
    
    [objectManager addFetchRequestBlock:^NSFetchRequest *(NSURL *URL) {
        RKPathMatcher *pathMatcher = [RKPathMatcher pathMatcherWithPattern:@"shops/:identifier"];
        
        NSDictionary *argsDict = nil;
        BOOL match = [pathMatcher matchesPath:[URL relativePath]
                         tokenizeQueryStrings:YES
                              parsedArguments:&argsDict];
        if (match) {
            NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"ShopCategory"];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"shop.identifier == %@", argsDict[@"identifier"]];
            return fetchRequest;
        }
        
        return nil;
    }];

    RKObjectMapping *upDownMapping = [RKObjectMapping mappingForClass:[HRPGTaskResponse class]];
    [upDownMapping addAttributeMappingsFromDictionary:@{
        @"delta" : @"delta",
        @"gp" : @"gold",
        @"lvl" : @"level",
        @"hp" : @"health",
        @"mp" : @"magic",
        @"exp" : @"experience",
        @"_tmp.drop.key" : @"dropKey",
        @"_tmp.drop.type" : @"dropType",
        @"_tmp.drop.dialog" : @"dropNote"
    }];
    [upDownMapping setAssignsDefaultValueForMissingAttributes:NO];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:upDownMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"tasks/:id/score/:direction"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *loginMapping = [RKObjectMapping mappingForClass:[HRPGLoginData class]];
    [loginMapping addAttributeMappingsFromDictionary:@{ @"id" : @"id", @"apiToken" : @"key" }];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:loginMapping
                               method:RKRequestMethodAny
                          pathPattern:@"user/auth/local/login"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:loginMapping
                               method:RKRequestMethodAny
                          pathPattern:@"user/auth/social"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:loginMapping
                               method:RKRequestMethodAny
                          pathPattern:@"user/auth/local/register"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *emptyMapping = [RKObjectMapping mappingForClass:[NSDictionary class]];
    [emptyMapping addAttributeMappingsFromDictionary:@{}];
    [RKMIMETypeSerialization registerClass:[HRPGEmptySerializer class] forMIMEType:@"text/plain"];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:emptyMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/sleep"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *gemPurchaseMapping =
        [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [gemPurchaseMapping addAttributeMappingsFromDictionary:@{
        @"ok" : @"ok",
        @"data.message" : @"message"
    }];
    [RKMIMETypeSerialization registerClass:[HRPGEmptySerializer class] forMIMEType:@"text/plain"];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:gemPurchaseMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"iap/ios/verify"
                              keyPath:nil
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *emptyStringMapping = [RKObjectMapping mappingForClass:[NSString class]];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:emptyStringMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/chat/seen"
                              keyPath:nil
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
                          responseDescriptorWithMapping:emptyStringMapping
                          method:RKRequestMethodPOST
                          pathPattern:@"user/mark-pms-read"
                          keyPath:nil
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    
    RKObjectMapping *feedMapping = [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [feedMapping addPropertyMapping:[RKAttributeMapping attributeMappingFromKeyPath:nil toKeyPath:@"value"]];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:feedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/feed/:pet/:food"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *entityMapping =
        [RKEntityMapping mappingForEntityForName:@"User" inManagedObjectStore:managedObjectStore];
    [entityMapping addAttributeMappingsFromDictionary:@{
        @"_id" : @"id",
        @"balance" : @"balance",
        @"profile.name" : @"username",
        @"auth.local.email" : @"email",
        @"stats.lvl" : @"level",
        @"stats.gp" : @"gold",
        @"stats.exp" : @"experience",
        @"stats.mp" : @"magic",
        @"stats.hp" : @"health",
        @"stats.class" : @"hclass",
        @"items.currentPet" : @"currentPet",
        @"items.currentMount" : @"currentMount",
        @"auth.timestamps.loggedin" : @"lastLogin",
        @"stats.con" : @"constitution",
        @"stats.int" : @"intelligence",
        @"stats.per" : @"perception",
        @"stats.str" : @"strength",
        @"stats.buff.con" : @"buffConstitution",
        @"stats.buff.int" : @"buffIntelligence",
        @"stats.buff.per" : @"buffPerception",
        @"stats.buff.str" : @"buffStrength",
        @"stats.training.con" : @"trainingConstitution",
        @"stats.training.int" : @"trainingIntelligence",
        @"stats.training.per" : @"trainingPerception",
        @"stats.training.str" : @"trainingStrength",
        @"contributor.level" : @"contributorLevel",
        @"contributor.text" : @"contributorText",
        @"contributor.contributions" : @"contributions",
        @"party.order" : @"partyOrder",
        @"party._id" : @"partyID",
        @"items.pets" : @"petCountArray",
        @"purchased" : @"customizationsDictionary",
        @"invitations.party.id" : @"invitedParty",
        @"invitations.party.name" : @"invitedPartyName",
        @"inbox.optOut" : @"inboxOptOut",
        @"inbox.newMessages" : @"inboxNewMessages",
        @"purchased.plan.consecutive.trinkets" : @"hourglasses"
    }];
    entityMapping.identificationAttributes = @[ @"id" ];
    RKEntityMapping *userTagMapping =
        [RKEntityMapping mappingForEntityForName:@"Tag" inManagedObjectStore:managedObjectStore];
    [userTagMapping addAttributeMappingsFromDictionary:@{
        @"id" : @"id",
        @"name" : @"name",
        @"challenge" : @"challenge",
        @"@metadata.mapping.collectionIndex" : @"order"
    }];
    userTagMapping.identificationAttributes = @[ @"id" ];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"tags"
                                                                       toKeyPath:@"tags"
                                                                     withMapping:userTagMapping]];
    RKEntityMapping *userOutfitMapping =
        [RKEntityMapping mappingForEntityForName:@"Outfit" inManagedObjectStore:managedObjectStore];
    [userOutfitMapping addAttributeMappingsFromDictionary:@{
        @"@parent.@parent.@parent._id" : @"userID",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    [userOutfitMapping addAttributeMappingsFromArray:@[
        @"armor", @"back", @"body", @"eyewear", @"head", @"headAccessory", @"shield", @"weapon"
    ]];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.gear.costume"
                                                               toKeyPath:@"costume"
                                                             withMapping:userOutfitMapping]];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.gear.equipped"
                                                               toKeyPath:@"equipped"
                                                             withMapping:userOutfitMapping]];

    RKEntityMapping *preferencesMapping =
        [RKEntityMapping mappingForEntityForName:@"Preferences"
                            inManagedObjectStore:managedObjectStore];
    [preferencesMapping addAttributeMappingsFromDictionary:@{
        @"@parent._id" : @"userID",
        @"allocationMode" : @"allocationMode",
        @"dayStart" : @"dayStart",
        @"disableClasses" : @"disableClass",
        @"sleep" : @"sleep",
        @"skin" : @"skin",
        @"size" : @"size",
        @"shirt" : @"shirt",
        @"hair.mustache" : @"hairMustache",
        @"hair.bangs" : @"hairBangs",
        @"hair.beard" : @"hairBeard",
        @"hair.base" : @"hairBase",
        @"hair.color" : @"hairColor",
        @"hair.flower" : @"hairFlower",
        @"background" : @"background",
        @"costume" : @"useCostume",
        @"language" : @"language",
        @"timezoneOffset" : @"timezoneOffset",
    }];
    preferencesMapping.identificationAttributes = @[ @"userID" ];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"preferences"
                                                               toKeyPath:@"preferences"
                                                             withMapping:preferencesMapping]];

    RKEntityMapping *improvementCategoryMapping =
        [RKEntityMapping mappingForEntityForName:@"ImprovementCategory"
                            inManagedObjectStore:managedObjectStore];
    [improvementCategoryMapping
        addAttributeMappingFromKeyOfRepresentationToAttribute:@"identifier"];
    [improvementCategoryMapping addAttributeMappingsFromDictionary:@{
        @"{identifier}" : @"isActive"
    }];
    improvementCategoryMapping.identificationAttributes = @[ @"identifier" ];
    [preferencesMapping
        addPropertyMapping:[RKRelationshipMapping
                               relationshipMappingFromKeyPath:@"improvementCategories"
                                                    toKeyPath:@"improvementCategories"
                                                  withMapping:improvementCategoryMapping]];

    RKEntityMapping *pushNotificationsMapping = [RKEntityMapping mappingForEntityForName:@"PushNotifications" inManagedObjectStore:managedObjectStore];
    [pushNotificationsMapping addAttributeMappingsFromArray:@[
                                                              @"giftedGems",
                                                              @"giftedSubscription",
                                                              @"invitedGuild",
                                                              @"invitedParty",
                                                              @"invitedQuest",
                                                              @"newPM",
                                                              @"questStarted",
                                                              @"wonChallenge",
                                                              @"unsubscribeFromAll"
                                                              ]];
    [pushNotificationsMapping addAttributeMappingsFromDictionary:@{@"@parent.@parent._id" : @"userID"}];
    [preferencesMapping addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"pushNotifications" toKeyPath:@"pushNotifications" withMapping:pushNotificationsMapping]];
    
    RKEntityMapping *flagsMapping =
        [RKEntityMapping mappingForEntityForName:@"Flags" inManagedObjectStore:managedObjectStore];
    [flagsMapping addAttributeMappingsFromDictionary:@{
        @"@parent._id" : @"userID",
        @"newStuff" : @"habitNewStuff",
        @"dropsEnabled" : @"dropsEnabled",
        @"itemsEnabled" : @"itemsEnabled",
        @"classSelected" : @"classSelected",
        @"armoireEnabled" : @"armoireEnabled",
        @"armoireEmpty" : @"armoireEmpty",
        @"communityGuidelinesAccepted" : @"communityGuidelinesAccepted",
    }];
    flagsMapping.identificationAttributes = @[ @"userID" ];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"flags"
                                                                       toKeyPath:@"flags"
                                                                     withMapping:flagsMapping]];

    RKEntityMapping *gearOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"Gear" inManagedObjectStore:managedObjectStore];
    gearOwnedMapping.forceCollectionMapping = YES;
    [gearOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [gearOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"owned" }];
    gearOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"items.gear.owned"
                                                                       toKeyPath:@"ownedGear"
                                                                     withMapping:gearOwnedMapping]];

    RKEntityMapping *questOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"Quest" inManagedObjectStore:managedObjectStore];
    questOwnedMapping.forceCollectionMapping = YES;
    [questOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [questOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"owned" }];
    questOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.quests"
                                                               toKeyPath:@"ownedQuests"
                                                             withMapping:questOwnedMapping]];

    RKEntityMapping *foodOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"Food" inManagedObjectStore:managedObjectStore];
    foodOwnedMapping.forceCollectionMapping = YES;
    [foodOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [foodOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"owned" }];
    foodOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"items.food"
                                                                       toKeyPath:@"ownedFood"
                                                                     withMapping:foodOwnedMapping]];

    RKEntityMapping *hPotionOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"HatchingPotion"
                            inManagedObjectStore:managedObjectStore];
    hPotionOwnedMapping.forceCollectionMapping = YES;
    [hPotionOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [hPotionOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"owned" }];
    hPotionOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.hatchingPotions"
                                                               toKeyPath:@"ownedHatchingPotions"
                                                             withMapping:hPotionOwnedMapping]];

    RKEntityMapping *eggOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"Egg" inManagedObjectStore:managedObjectStore];
    eggOwnedMapping.forceCollectionMapping = YES;
    [eggOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [eggOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"owned" }];
    eggOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"items.eggs"
                                                                       toKeyPath:@"ownedEggs"
                                                                     withMapping:eggOwnedMapping]];

    RKEntityMapping *petOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"Pet" inManagedObjectStore:managedObjectStore];
    petOwnedMapping.forceCollectionMapping = YES;
    [petOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [petOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"trained" }];
    petOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"items.pets"
                                                                       toKeyPath:@"ownedPets"
                                                                     withMapping:petOwnedMapping]];

    RKEntityMapping *mountOwnedMapping =
        [RKEntityMapping mappingForEntityForName:@"Pet" inManagedObjectStore:managedObjectStore];
    mountOwnedMapping.forceCollectionMapping = YES;
    [mountOwnedMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [mountOwnedMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"asMount" }];
    mountOwnedMapping.identificationAttributes = @[ @"key" ];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.mounts"
                                                               toKeyPath:@"ownedMounts"
                                                             withMapping:mountOwnedMapping]];

    RKEntityMapping *newMessageMapping =
        [RKEntityMapping mappingForEntityForName:@"Group" inManagedObjectStore:managedObjectStore];
    newMessageMapping.forceCollectionMapping = YES;
    [newMessageMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"id"];
    [newMessageMapping addAttributeMappingsFromDictionary:@{ @"(id).value" : @"unreadMessages" }];
    newMessageMapping.identificationAttributes = @[ @"id" ];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"newMessages"
                                                               toKeyPath:@"groups"
                                                             withMapping:newMessageMapping]];

    RKEntityMapping *tutorialsSeenMapping =
        [RKEntityMapping mappingForEntityForName:@"TutorialSteps"
                            inManagedObjectStore:managedObjectStore];
    tutorialsSeenMapping.forceCollectionMapping = YES;
    [tutorialsSeenMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"identifier"];
    [tutorialsSeenMapping addAttributeMappingsFromDictionary:@{
        @"(identifier)" : @"wasShown",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    tutorialsSeenMapping.identificationAttributes = @[ @"identifier" ];
    [flagsMapping addPropertyMapping:[RKRelationshipMapping
                                         relationshipMappingFromKeyPath:@"tutorial.ios"
                                                              toKeyPath:@"iOSTutorialSteps"
                                                            withMapping:tutorialsSeenMapping]];
    [flagsMapping addPropertyMapping:[RKRelationshipMapping
                                         relationshipMappingFromKeyPath:@"tutorial.common"
                                                              toKeyPath:@"commonTutorialSteps"
                                                            withMapping:tutorialsSeenMapping]];

    RKEntityMapping *taskOrderMapping = [RKEntityMapping mappingForEntityForName:@"Task" inManagedObjectStore:managedObjectStore];
    [taskOrderMapping addPropertyMapping:[RKAttributeMapping attributeMappingFromKeyPath:nil toKeyPath:@"id"]];
    [taskOrderMapping addPropertyMapping:[RKAttributeMapping attributeMappingFromKeyPath:@"@metadata.mapping.collectionIndex" toKeyPath:@"order"]];
    taskOrderMapping.identificationAttributes = @[ @"id" ];
    
    responseDescriptor = [RKResponseDescriptor
                          responseDescriptorWithMapping:taskOrderMapping
                          method:RKRequestMethodAny
                          pathPattern:@"user"
                          keyPath:@"data.tasksOrder.habits"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
                          responseDescriptorWithMapping:taskOrderMapping
                          method:RKRequestMethodAny
                          pathPattern:@"user"
                          keyPath:@"data.tasksOrder.todos"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
                          responseDescriptorWithMapping:taskOrderMapping
                          method:RKRequestMethodAny
                          pathPattern:@"user"
                          keyPath:@"data.tasksOrder.dailys"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    
    RKEntityMapping *inboxMessageMapping = [RKEntityMapping mappingForEntityForName:@"InboxMessage"
                                                       inManagedObjectStore:managedObjectStore];
    [inboxMessageMapping setForceCollectionMapping:YES];
    [inboxMessageMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"id"];
    [inboxMessageMapping setIdentificationAttributes:@[@"id"]];
    [inboxMessageMapping addAttributeMappingsFromDictionary:@{
                                                      @"(id).text" : @"text",
                                                      @"(id).timestamp" : @"timestamp",
                                                      @"(id).user" : @"username",
                                                      @"(id).uuid" : @"userID",
                                                      @"(id).sent" : @"sent",
                                                      @"(id).contributor.level" : @"contributorLevel",
                                                      @"(id).contributor.text" : @"contributorText",
                                                      @"(id).backer.tier" : @"backerLevel",
                                                      @"(id).backer.npc" : @"backerNpc",
                                                      @"(id).sort" : @"sort"
                                                      }];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                       relationshipMappingFromKeyPath:@"inbox.messages"
                                       toKeyPath:@"inboxMessages"
                                       withMapping:inboxMessageMapping]];
    
    RKEntityMapping *pushDeviceMapping = [RKEntityMapping mappingForEntityForName:@"PushDevice"
                                                               inManagedObjectStore:managedObjectStore];
    [pushDeviceMapping setForceCollectionMapping:YES];
    [pushDeviceMapping setIdentificationAttributes:@[@"regId"]];
    [pushDeviceMapping addAttributeMappingsFromDictionary:@{
                                                              @"regId" : @"regId",
                                                              @"type" : @"type"
                                                              }];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                       relationshipMappingFromKeyPath:@"pushDevices"
                                       toKeyPath:@"pushDevices"
                                       withMapping:pushDeviceMapping]];
    
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/class/cast/:spell"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/revive"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/change-class"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/disable-classes"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/unlock"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/purchase/:type/:item"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *equipMapping = [RKObjectMapping mappingForClass:[HRPGUserBuyResponse class]];
    [equipMapping addAttributeMappingsFromDictionary:@{
        @"gear.equipped.headAccessory" : @"equippedHeadAccessory",
        @"gear.equipped.armor" : @"equippedArmor",
        @"gear.equipped.body" : @"equippedBody",
        @"gear.equipped.eyewear" : @"equippedEyewear",
        @"gear.equipped.head" : @"equippedHead",
        @"gear.equipped.shield" : @"equippedShield",
        @"gear.equipped.weapon" : @"equippedWeapon",
        @"gear.equipped.back" : @"equippedBack",
        @"gear.costume.headAccessory" : @"costumeHeadAccessory",
        @"gear.costume.armor" : @"costumeArmor",
        @"gear.costume.back" : @"costumeBack",
        @"gear.costume.body" : @"costumeBody",
        @"gear.costume.eyewear" : @"costumeEyewear",
        @"gear.costume.head" : @"costumeHead",
        @"gear.costume.shield" : @"costumeShield",
        @"gear.costume.weapon" : @"costumeWeapon",
        @"currentPet" : @"currentPet",
        @"currentMount" : @"currentMount",
    }];
    equipMapping.assignsDefaultValueForMissingAttributes = NO;
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:equipMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/equip/:type/:key"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:eggOwnedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/equip/:type/:key"
                              keyPath:@"data.eggs"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:petOwnedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/equip/:type/:key"
                              keyPath:@"data.pets"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:hPotionOwnedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/equip/:type/:key"
                              keyPath:@"data.hatchingPotions"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:equipMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/hatch/:egg/:hatchingPotion"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:eggOwnedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/hatch/:egg/:hatchingPotion"
                              keyPath:@"data.eggs"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:petOwnedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/hatch/:egg/:hatchingPotion"
                              keyPath:@"data.pets"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:hPotionOwnedMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/hatch/:egg/:hatchingPotion"
                              keyPath:@"data.hatchingPotions"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    entityMapping.assignsDefaultValueForMissingAttributes = YES;

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPUT
                          pathPattern:@"user"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    [entityMapping addAttributeMappingsFromDictionary:@{
        @"stats.toNextLevel" : @"nextLevel",
        @"stats.maxHealth" : @"maxHealth",
        @"stats.maxMP" : @"maxMagic",
    }];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodGET
                          pathPattern:@"user"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];


    RKObjectMapping *buyMapping = [RKObjectMapping mappingForClass:[HRPGUserBuyResponse class]];
    [buyMapping addAttributeMappingsFromDictionary:@{
        @"lvl" : @"level",
        @"gp" : @"gold",
        @"exp" : @"experience",
        @"mp" : @"magic",
        @"hp" : @"health",
        @"items.gear.equipped.headAccessory" : @"equippedHeadAccessory",
        @"items.gear.equipped.armor" : @"equippedArmor",
        @"items.gear.equipped.back" : @"equippedBack",
        @"items.gear.equipped.body" : @"equippedBody",
        @"items.gear.equipped.eyewear" : @"equippedEyewear",
        @"items.gear.equipped.head" : @"equippedHead",
        @"items.gear.equipped.shield" : @"equippedShield",
        @"items.gear.equipped.weapon" : @"equippedWeapon",
        @"items.gear.costume.headAccessory" : @"costumeHeadAccessory",
        @"items.gear.costume.armor" : @"costumeArmor",
        @"items.gear.costume.back" : @"costumeBack",
        @"items.gear.costume.body" : @"costumeBody",
        @"items.gear.costume.eyewear" : @"costumeEyewear",
        @"items.gear.costume.head" : @"costumeHead",
        @"items.gear.costume.shield" : @"costumeShield",
        @"items.gear.costume.weapon" : @"costumeWeapon",
        @"items.currentPet" : @"currentPet",
        @"items.currentMount" : @"currentMount",
        @"armoire.type" : @"armoireType",
        @"armoire.dropKey" : @"armoireKey",
        @"armoire.dropArticle" : @"armoireArticle",
        @"armoire.dropText" : @"armoireText",
        @"armoire.value" : @"armoireValue",
    }];
    buyMapping.assignsDefaultValueForMissingAttributes = NO;
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:buyMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/buy/:key"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    buyMapping.assignsDefaultValueForMissingAttributes = NO;
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:buyMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"user/sell/:type/:key"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    entityMapping =
        [RKEntityMapping mappingForEntityForName:@"Group" inManagedObjectStore:managedObjectStore];
    [entityMapping addAttributeMappingsFromDictionary:@{
        @"_id" : @"id",
        @"name" : @"name",
        @"description" : @"hdescription",
        @"quest.key" : @"questKey",
        @"quest.progress.hp" : @"questHP",
        @"quest.progress.rage" : @"questRage",
        @"quest.active" : @"questActive",
        @"quest.leader" : @"questLeader",
        @"quest.extra.worldDmg.tavern" : @"worldDmgTavern",
        @"quest.extra.worldDmg.stable" : @"worldDmgStable",
        @"quest.extra.worldDmg.market" : @"worldDmgMarket",
        @"privacy" : @"privacy",
        @"type" : @"type",
        @"memberCount" : @"memberCount",
        @"balance" : @"balance"
    }];
    entityMapping.identificationAttributes = @[ @"id" ];
    entityMapping.assignsDefaultValueForMissingAttributes = YES;
    RKEntityMapping *chatMapping = [RKEntityMapping mappingForEntityForName:@"ChatMessage"
                                                       inManagedObjectStore:managedObjectStore];
    [chatMapping addAttributeMappingsFromDictionary:@{
        @"id" : @"id",
        @"text" : @"text",
        @"timestamp" : @"timestamp",
        @"user" : @"user",
        @"uuid" : @"uuid",
        @"contributor.level" : @"contributorLevel",
        @"contributor.text" : @"contributorText",
        @"backer.tier" : @"backerLevel",
        @"backer.npc" : @"backerNpc"
    }];
    RKEntityMapping *chatUserMapping =
        [RKEntityMapping mappingForEntityForName:@"User" inManagedObjectStore:managedObjectStore];
    [chatUserMapping addAttributeMappingsFromDictionary:@{ @"uuid" : @"id" }];
    [chatMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:nil
                                                                       toKeyPath:@"userObject"
                                                                     withMapping:chatUserMapping]];
    RKEntityMapping *likeMapping = [RKEntityMapping mappingForEntityForName:@"ChatMessageLike"
                                                       inManagedObjectStore:managedObjectStore];
    likeMapping.forceCollectionMapping = YES;
    [likeMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"userID"];
    likeMapping.identificationAttributes = @[ @"userID" ];
    [chatMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"likes"
                                                                       toKeyPath:@"likes"
                                                                     withMapping:likeMapping]];
    [entityMapping
        addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"chat"
                                                                       toKeyPath:@"chatmessages"
                                                                     withMapping:chatMapping]];
    chatMapping.identificationAttributes = @[ @"id" ];
    RKEntityMapping *collectMapping = [RKEntityMapping mappingForEntityForName:@"QuestCollect"
                                                          inManagedObjectStore:managedObjectStore];
    collectMapping.forceCollectionMapping = YES;
    [collectMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [collectMapping addAttributeMappingsFromDictionary:@{ @"(key)" : @"collectCount" }];
    collectMapping.identificationAttributes = @[ @"key" ];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"quest.progress.collect"
                                                               toKeyPath:@"collectStatus"
                                                             withMapping:collectMapping]];
    RKEntityMapping *questParticipantsMapping =
        [RKEntityMapping mappingForEntityForName:@"User" inManagedObjectStore:managedObjectStore];
    questParticipantsMapping.forceCollectionMapping = YES;
    [questParticipantsMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"id"];
    [questParticipantsMapping addAttributeMappingsFromDictionary:@{
        @"(id)" : @"participateInQuest"
    }];
    questParticipantsMapping.identificationAttributes = @[ @"id" ];
    questParticipantsMapping.assignsDefaultValueForMissingAttributes = YES;
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"quest.members"
                                                               toKeyPath:@"questParticipants"
                                                             withMapping:questParticipantsMapping]];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/quests/accept"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/quests/reject"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/quests/abort"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/quests/invite/:questKey"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/quests/force-start"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/quests/cancel"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:emptyMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/invite"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/join"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/leave"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *groupRequestMapping =
        [RKObjectMapping mappingForClass:[NSMutableDictionary class]];
    [groupRequestMapping addAttributeMappingsFromDictionary:@{
        @"id" : @"_id",
        @"name" : @"name",
        @"hdescription" : @"description",
        @"type" : @"type",
        @"leader.id" : @"leader"
    }];

    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Group class]
                             pathPattern:@"groups/:id"
                                  method:RKRequestMethodGET]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Group class]
                             pathPattern:@"groups/:id"
                                  method:RKRequestMethodPUT]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Group class]
                             pathPattern:@"groups"
                                  method:RKRequestMethodPOST]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[Group class]
                             pathPattern:@"groups/:id"
                                  method:RKRequestMethodDELETE]];

    requestDescriptor = [RKRequestDescriptor requestDescriptorWithMapping:groupRequestMapping
                                                              objectClass:[Group class]
                                                              rootKeyPath:nil
                                                                   method:RKRequestMethodPOST];
    [objectManager addRequestDescriptor:requestDescriptor];
    requestDescriptor = [RKRequestDescriptor requestDescriptorWithMapping:groupRequestMapping
                                                              objectClass:[Group class]
                                                              rootKeyPath:nil
                                                                   method:RKRequestMethodPUT];
    [objectManager addRequestDescriptor:requestDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:chatMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/chat"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:chatMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/chat/:key/like"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:chatMapping
                               method:RKRequestMethodPOST
                          pathPattern:@"groups/:id/chat/:key/flag"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:chatMapping
                               method:RKRequestMethodDELETE
                          pathPattern:@"groups/:id/chat/:key"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[ChatMessage class]
                             pathPattern:@"groups/:group.id/chat"
                                  method:RKRequestMethodPOST]];
    [[RKObjectManager sharedManager].router.routeSet
        addRoute:[RKRoute routeWithClass:[ChatMessage class]
                             pathPattern:@"groups/:group.id/chat/:id"
                                  method:RKRequestMethodDELETE]];

    RKEntityMapping *memberMapping =
        [RKEntityMapping mappingForEntityForName:@"User" inManagedObjectStore:managedObjectStore];
    [memberMapping addAttributeMappingsFromDictionary:@{
        @"_id" : @"id",
        @"profile.name" : @"username",
        @"profile.blurb" : @"blurb",
        @"stats.lvl" : @"level",
        @"stats.gp" : @"gold",
        @"stats.exp" : @"experience",
        @"stats.mp" : @"magic",
        @"stats.hp" : @"health",
        @"stats.toNextLevel" : @"nextLevel",
        @"stats.maxHealth" : @"maxHealth",
        @"stats.maxMP" : @"maxMagic",
        @"stats.class" : @"hclass",
        @"items.currentPet" : @"currentPet",
        @"items.currentMount" : @"currentMount",
        @"auth.timestamps.loggedin" : @"lastLogin",
        @"auth.timestamps.created" : @"memberSince",
        @"stats.con" : @"constitution",
        @"stats.int" : @"intelligence",
        @"stats.per" : @"perception",
        @"stats.str" : @"strength",
        @"stats.buff.con" : @"buffConstitution",
        @"stats.buff.int" : @"buffIntelligence",
        @"stats.buff.per" : @"buffPerception",
        @"stats.buff.str" : @"buffStrength",
        @"stats.training.con" : @"trainingConstitution",
        @"stats.training.int" : @"trainingIntelligence",
        @"stats.training.per" : @"trainingPerception",
        @"stats.training.str" : @"trainingStrength",
        @"contributor.level" : @"contributorLevel",
        @"contributor.text" : @"contributorText",
        @"@metadata.mapping.collectionIndex" : @"partyPosition",
        @"party.order" : @"partyOrder",
        @"party._id" : @"partyID",
        @"items.pets" : @"petCountArray"
    }];
    memberMapping.identificationAttributes = @[ @"id" ];

    [memberMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.gear.costume"
                                                               toKeyPath:@"costume"
                                                             withMapping:userOutfitMapping]];
    [memberMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"items.gear.equipped"
                                                               toKeyPath:@"equipped"
                                                             withMapping:userOutfitMapping]];

    [memberMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"preferences"
                                                               toKeyPath:@"preferences"
                                                             withMapping:preferencesMapping]];

    RKEntityMapping *memberIdMapping =
        [RKEntityMapping mappingForEntityForName:@"User" inManagedObjectStore:managedObjectStore];
    [memberIdMapping
        addPropertyMapping:[RKAttributeMapping attributeMappingFromKeyPath:nil toKeyPath:@"id"]];
    memberIdMapping.identificationAttributes = @[ @"id" ];
    RKDynamicMapping *dynamicMemberMapping = [RKDynamicMapping new];
    [dynamicMemberMapping
        setObjectMappingForRepresentationBlock:^RKObjectMapping *(id representation) {
            if ([representation isKindOfClass:[NSString class]]) {
                return memberIdMapping;
            }
            return memberMapping;
        }];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:memberMapping
                               method:RKRequestMethodAny
                          pathPattern:@"groups/:id/members"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    [entityMapping addPropertyMapping:[RKRelationshipMapping
                                          relationshipMappingFromKeyPath:@"leader"
                                                               toKeyPath:@"leader"
                                                             withMapping:dynamicMemberMapping]];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodAny
                          pathPattern:@"groups/:id"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:entityMapping
                               method:RKRequestMethodAny
                          pathPattern:@"groups"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];

    [objectManager addResponseDescriptor:responseDescriptor];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:memberMapping
                               method:RKRequestMethodGET
                          pathPattern:@"members/:id"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];

    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *gearMapping =
        [RKEntityMapping mappingForEntityForName:@"Gear" inManagedObjectStore:managedObjectStore];
    gearMapping.forceCollectionMapping = YES;
    [gearMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [gearMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).notes" : @"notes",
        @"(key).con" : @"con",
        @"(key).value" : @"value",
        @"(key).type" : @"type",
        @"(key).klass" : @"klass",
        @"(key).index" : @"index",
        @"(key).str" : @"str",
        @"(key).int" : @"intelligence",
        @"(key).per" : @"per",
        @"(key).event.start" : @"eventStart",
        @"(key).event.end" : @"eventEnd",
        @"(key).specialClass" : @"specialClass",
        @"(key).gearSet" : @"set"
    }];
    gearMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:gearMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.gear.flat"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    gearMapping =
        [RKEntityMapping mappingForEntityForName:@"Gear" inManagedObjectStore:managedObjectStore];
    [gearMapping addAttributeMappingsFromDictionary:@{
        @"key" : @"key",
        @"text" : @"text",
        @"notes" : @"notes",
        @"con" : @"con",
        @"value" : @"value",
        @"type" : @"type",
        @"klass" : @"klass",
        @"index" : @"index",
        @"str" : @"str",
        @"int" : @"intelligence",
        @"per" : @"per",
        @"event.start" : @"eventStart",
        @"event.end" : @"eventEnd",
        @"specialClass" : @"specialClass",
        @"gearSet" : @"set"
    }];
    gearMapping.identificationAttributes = @[ @"key" ];
    gearMapping.assignsDefaultValueForMissingAttributes = NO;
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:gearMapping
                               method:RKRequestMethodGET
                          pathPattern:@"user/inventory/buy"
                              keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *eggMapping =
        [RKEntityMapping mappingForEntityForName:@"Egg" inManagedObjectStore:managedObjectStore];
    eggMapping.forceCollectionMapping = YES;
    [eggMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [eggMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).adjective" : @"adjective",
        @"(key).canBuy" : @"canBuy",
        @"(key).value" : @"value",
        @"(key).notes" : @"notes",
        @"(key).mountText" : @"mountText",
        @"(key).dialog" : @"dialog",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    eggMapping.identificationAttributes = @[ @"key" ];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:eggMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.eggs"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    RKEntityMapping *hatchingPotionMapping =
        [RKEntityMapping mappingForEntityForName:@"HatchingPotion"
                            inManagedObjectStore:managedObjectStore];
    hatchingPotionMapping.forceCollectionMapping = YES;
    [hatchingPotionMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [hatchingPotionMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).value" : @"value",
        @"(key).notes" : @"notes",
        @"(key).dialog" : @"dialog",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    hatchingPotionMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:hatchingPotionMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.hatchingPotions"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    RKEntityMapping *foodMapping =
        [RKEntityMapping mappingForEntityForName:@"Food" inManagedObjectStore:managedObjectStore];
    foodMapping.forceCollectionMapping = YES;
    [foodMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [foodMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).target" : @"target",
        @"(key).canBuy" : @"canBuy",
        @"(key).value" : @"value",
        @"(key).notes" : @"notes",
        @"(key).article" : @"article",
        @"(key).dialog" : @"dialog",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    foodMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:foodMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.food"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    RKEntityMapping *spellMapping =
        [RKEntityMapping mappingForEntityForName:@"Spell" inManagedObjectStore:managedObjectStore];
    spellMapping.forceCollectionMapping = YES;
    [spellMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [spellMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).lvl" : @"level",
        @"(key).notes" : @"notes",
        @"(key).mana" : @"mana",
        @"(key).target" : @"target",
        @"@metadata.mapping.rootKeyPath" : @"klass"
    }];
    spellMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:spellMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.spells.healer"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:spellMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.spells.wizard"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:spellMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.spells.warrior"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:spellMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.spells.rogue"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *potionMapping =
        [RKEntityMapping mappingForEntityForName:@"Potion" inManagedObjectStore:managedObjectStore];
    [potionMapping addAttributeMappingsFromDictionary:@{
        @"text" : @"text",
        @"key" : @"key",
        @"value" : @"value",
        @"notes" : @"notes",
        @"type" : @"type",
    }];
    potionMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:potionMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.potion"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    RKEntityMapping *armoireMapping = [RKEntityMapping mappingForEntityForName:@"Armoire"
                                                          inManagedObjectStore:managedObjectStore];
    [armoireMapping addAttributeMappingsFromDictionary:@{
        @"text" : @"text",
        @"key" : @"key",
        @"value" : @"value",
        @"notes" : @"notes",
        @"type" : @"type",
    }];
    armoireMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:armoireMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.armoire"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    RKEntityMapping *questMapping =
        [RKEntityMapping mappingForEntityForName:@"Quest" inManagedObjectStore:managedObjectStore];
    questMapping.forceCollectionMapping = YES;
    [questMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    RKEntityMapping *questCollectMapping =
        [RKEntityMapping mappingForEntityForName:@"QuestCollect"
                            inManagedObjectStore:managedObjectStore];
    questCollectMapping.forceCollectionMapping = YES;
    [questCollectMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [questCollectMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).count" : @"count"
    }];
    questCollectMapping.identificationAttributes = @[ @"key" ];
    [questMapping addPropertyMapping:[RKRelationshipMapping
                                         relationshipMappingFromKeyPath:@"(key).collect"
                                                              toKeyPath:@"collect"
                                                            withMapping:questCollectMapping]];
    [questMapping addAttributeMappingsFromDictionary:@{
        @"(key).text" : @"text",
        @"(key).completition" : @"completition",
        @"(key).canBuy" : @"canBuy",
        @"(key).value" : @"value",
        @"(key).notes" : @"notes",
        @"(key).drop.gp" : @"dropGp",
        @"(key).drop.exp" : @"dropExp",
        @"(key).boss.name" : @"bossName",
        @"(key).boss.hp" : @"bossHp",
        @"(key).boss.str" : @"bossStr",
        @"(key).boss.def" : @"bossDef",
        @"(key).boss.rage.title" : @"rageTitle",
        @"(key).boss.rage.value" : @"bossRage",
        @"(key).boss.rage.description" : @"rageDescription",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    questMapping.identificationAttributes = @[ @"key" ];

    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:questMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.quests"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *backgroundMapping =
        [RKEntityMapping mappingForEntityForName:@"Customization"
                            inManagedObjectStore:managedObjectStore];
    backgroundMapping.forceCollectionMapping = YES;
    [backgroundMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"name"];
    [backgroundMapping addAttributeMappingsFromDictionary:@{
        @"(name).text" : @"text",
        @"(name).notes" : @"notes",
        @"(name).set.key" : @"set",
        @"(name).price" : @"price",
        @"@metadata.mapping.rootKeyPath" : @"type"
    }];
    backgroundMapping.identificationAttributes = @[ @"name" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:backgroundMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.appearances.background"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *petMapping =
        [RKEntityMapping mappingForEntityForName:@"Pet" inManagedObjectStore:managedObjectStore];
    petMapping.forceCollectionMapping = YES;
    [petMapping addAttributeMappingFromKeyOfRepresentationToAttribute:@"key"];
    [petMapping addAttributeMappingsFromDictionary:@{ @"@metadata.mapping.rootKeyPath" : @"type" }];
    petMapping.identificationAttributes = @[ @"key" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:petMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.pets"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:petMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.questPets"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKEntityMapping *faqMapping =
        [RKEntityMapping mappingForEntityForName:@"FAQ" inManagedObjectStore:managedObjectStore];
    [faqMapping addAttributeMappingsFromDictionary:@{
        @"question" : @"question",
        @"ios" : @"iosAnswer",
        @"web" : @"webAnswer",
        @"mobile" : @"mobileAnswer",
        @"@metadata.mapping.collectionIndex" : @"index"
    }];
    faqMapping.identificationAttributes = @[ @"question" ];
    responseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:faqMapping
                               method:RKRequestMethodGET
                          pathPattern:@"content"
                              keyPath:@"data.faq.questions"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];

    RKObjectMapping *errorMapping = [RKObjectMapping mappingForClass:[RKErrorMessage class]];

    [errorMapping
        addPropertyMapping:[RKAttributeMapping attributeMappingFromKeyPath:@"message"
                                                                 toKeyPath:@"errorMessage"]];
    RKResponseDescriptor *errorResponseDescriptor = [RKResponseDescriptor
        responseDescriptorWithMapping:errorMapping
                               method:RKRequestMethodAny
                          pathPattern:nil
                              keyPath:nil
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassClientError)];
    [objectManager addResponseDescriptor:errorResponseDescriptor];

    RKObjectMapping *messageMapping = [RKObjectMapping mappingForClass:[HRPGResponseMessage class]];
    [messageMapping
     addPropertyMapping:[RKAttributeMapping attributeMappingFromKeyPath:@"message"
                                                              toKeyPath:@"message"]];
    RKResponseDescriptor *messageResponseDescriptor = [RKResponseDescriptor
                                                     responseDescriptorWithMapping:messageMapping
                                                     method:RKRequestMethodAny
                                                     pathPattern:nil
                                                     keyPath:nil
                                                     statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:messageResponseDescriptor];
    
    RKEntityMapping *shopMapping = [RKEntityMapping mappingForEntityForName:@"Shop"
                                                       inManagedObjectStore:managedObjectStore];
    [shopMapping addAttributeMappingsFromArray:@[@"text", @"identifier", @"notes", @"imageName", @"purchaseAll"]];
    shopMapping.identificationAttributes = @[ @"identifier" ];
    RKEntityMapping *shopCategoryMapping = [RKEntityMapping mappingForEntityForName:@"ShopCategory" inManagedObjectStore:managedObjectStore];
    [shopCategoryMapping addAttributeMappingsFromArray:@[@"text", @"identifier", @"notes", @"purchaseAll"]];
    [shopCategoryMapping addAttributeMappingsFromDictionary:@{@"@metadata.mapping.collectionIndex": @"index"}];
    shopCategoryMapping.identificationAttributes = @[ @"identifier" ];
    [shopMapping
     addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"categories"
                                                                    toKeyPath:@"categories"
                                                                  withMapping:shopCategoryMapping]];
    RKEntityMapping *shopItemMapping = [RKEntityMapping mappingForEntityForName:@"ShopItem" inManagedObjectStore:managedObjectStore];
    [shopItemMapping addAttributeMappingsFromArray:@[@"text", @"key", @"notes", @"type", @"value", @"currency", @"locked", @"purchaseType"]];
    [shopItemMapping addAttributeMappingsFromDictionary:@{@"@metadata.mapping.collectionIndex": @"index",
                                                          @"class": @"imageName"}];
    shopItemMapping.identificationAttributes = @[ @"key", @"purchaseType" ];
    [shopCategoryMapping
     addPropertyMapping:[RKRelationshipMapping relationshipMappingFromKeyPath:@"items"
                                                                    toKeyPath:@"items"
                                                                  withMapping:shopItemMapping]];
    responseDescriptor = [RKResponseDescriptor
                          responseDescriptorWithMapping:shopMapping
                          method:RKRequestMethodGET
                          pathPattern:@"shops/:shopUrl"
                          keyPath:@"data"
                          statusCodes:RKStatusCodeIndexSetForClass(RKStatusCodeClassSuccessful)];
    [objectManager addResponseDescriptor:responseDescriptor];
    
    
    [[RKObjectManager sharedManager].HTTPClient setDefaultHeader:@"x-client" value:@"habitica-ios"];

    [self setCredentials];
    defaults = [NSUserDefaults standardUserDefaults];
    if (currentUser != nil && currentUser.length > 0) {
        NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"User"];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"id==%@", currentUser];
        [fetchRequest setPredicate:predicate];
        NSArray *fetchedObjects =
            [[self getManagedObjectContext] executeFetchRequest:fetchRequest error:&error];
        if ([fetchedObjects count] > 0) {
            self.user = fetchedObjects[0];
        } else {
            [self fetchUser:nil onError:nil];
        }
    }

    self.networkIndicatorController = [[HRPGNetworkIndicatorController alloc] init];
}

- (NIKFontAwesomeIconFactory *)iconFactory {
    if (_iconFactory == nil) {
        _iconFactory = [NIKFontAwesomeIconFactory tabBarItemIconFactory];
        _iconFactory.colors = @[ [UIColor whiteColor] ];
        _iconFactory.size = 35;
    }
    return _iconFactory;
}

- (void)resetSavedDatabase:(BOOL)withUserData onComplete:(void (^)())completitionBlock {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"startClearingData" object:nil];
    YYImageCache *cache = [YYWebImageManager sharedManager].cache;
    [cache.memoryCache removeAllObjects];
    [cache.diskCache removeAllObjects];
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        [[self getManagedObjectContext] performBlockAndWait:^{
            NSError *error = nil;
            for (NSEntityDescription *entity in [RKManagedObjectStore defaultStore]
                     .managedObjectModel) {
                NSFetchRequest *fetchRequest = [NSFetchRequest new];
                [fetchRequest setEntity:entity];
                [fetchRequest setIncludesSubentities:NO];
                NSArray *objects =
                    [[self getManagedObjectContext] executeFetchRequest:fetchRequest error:&error];
                if (!objects)
                    RKLogWarning(@"Failed execution of fetch request %@: %@", fetchRequest, error);
                for (NSManagedObject *managedObject in objects) {
                    [[self getManagedObjectContext] deleteObject:managedObject];
                }
            }
            [[self getManagedObjectContext] processPendingChanges];
            BOOL success = [[self getManagedObjectContext] save:&error];
            if (!success) RKLogWarning(@"Failed saving managed object context: %@", error);
        }];
    }];
    operation.completionBlock = ^{
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        NSError *error;
        [[self getManagedObjectContext] saveToPersistentStore:&error];
        if (!error) {
            BOOL success = [[self getManagedObjectContext] save:&error];
            if (!success) RKLogWarning(@"Failed saving managed object context: %@", error);
            [self fetchContent:^() {
                NSError *error;
                [[self getManagedObjectContext] processPendingChanges];
                [[self getManagedObjectContext] saveToPersistentStore:&error];
                if (withUserData) {
                    [self fetchUser:^() {
                        completitionBlock();
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"finishedClearingData"
                                          object:nil];
                    }
                        onError:^() {
                            [[NSNotificationCenter defaultCenter]
                                postNotificationName:@"finishedClearingData"
                                              object:nil];
                            completitionBlock();
                        }];
                } else {
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:@"finishedClearingData"
                                      object:nil];
                    completitionBlock();
                }
            }
                onError:^() {
                    NSError *error;
                    [[self getManagedObjectContext] processPendingChanges];
                    [[self getManagedObjectContext] saveToPersistentStore:&error];
                    if (withUserData) {
                        [self fetchUser:^() {
                            [[NSNotificationCenter defaultCenter]
                                postNotificationName:@"finishedClearingData"
                                              object:nil];
                            completitionBlock();
                        }
                            onError:^() {
                                [[NSNotificationCenter defaultCenter]
                                    postNotificationName:@"finishedClearingData"
                                                  object:nil];
                                completitionBlock();
                            }];
                    } else {
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"finishedClearingData"
                                          object:nil];
                        completitionBlock();
                    }
                }];
        }
    };
    [operation start];
}

- (NSManagedObjectContext *)getManagedObjectContext {
    return [managedObjectStore mainQueueManagedObjectContext];
}

- (void)setCredentials {
    PDKeychainBindings *keyChain = [PDKeychainBindings sharedKeychainBindings];
    currentUser = [keyChain stringForKey:@"id"];
    [[RKObjectManager sharedManager].HTTPClient setDefaultHeader:@"x-api-user" value:currentUser];
    [[RKObjectManager sharedManager].HTTPClient setDefaultHeader:@"x-api-key"
                                                           value:[keyChain stringForKey:@"key"]];

    id<GAITracker> tracker = [[GAI sharedInstance] defaultTracker];
    [tracker set:@"&uid" value:self.user.id];
    [[Amplitude instance] setUserId:currentUser];
    [[Crashlytics sharedInstance] setUserIdentifier:currentUser];
    [[Crashlytics sharedInstance] setUserName:currentUser];
}

- (void)clearLoginCredentials {
    [[RKObjectManager sharedManager].HTTPClient setDefaultHeader:@"x-api-user" value:@""];
    [[RKObjectManager sharedManager].HTTPClient setDefaultHeader:@"x-api-key" value:@""];
}

- (void)setTimezoneOffset {
    NSInteger offset = -[[NSTimeZone localTimeZone] secondsFromGMT] / 60;
    if (self.user.preferences) {
        if (!self.user.preferences.timezoneOffset ||
            offset != [self.user.preferences.timezoneOffset integerValue]) {
            self.user.preferences.timezoneOffset = @(offset);
            [self updateUser:@{
                @"preferences.timezoneOffset" : @(offset)
            }
                   onSuccess:nil
                     onError:nil];
        }
    }
}

- (void)fetchContent:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    NSString *url = @"content";
    if (self.user.preferences.language) {
        url = [url stringByAppendingFormat:@"?language=%@", self.user.preferences.language];
        [defaults setObject:self.user.preferences.language forKey:@"contentLanguage"];
        [defaults synchronize];
    }

    [[RKObjectManager sharedManager] getObjectsAtPath:url
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            for (NSDictionary *dict in [mappingResult dictionary][@"backgrounds"]) {
                for (Customization *background in dict[@"backgrounds"]) {
                    background.type = @"background";
                    background.set = dict[@"setName"];
                    background.price = @7;
                    // TODO: Figure out why it is necessary to save each background individually
                    [background.managedObjectContext saveToPersistentStore:&executeError];
                }
            }

            NSString *textPath =
                [[NSBundle mainBundle] pathForResource:@"customizations" ofType:@"json"];
            NSError *error;
            NSString *content = [NSString stringWithContentsOfFile:textPath
                                                          encoding:NSUTF8StringEncoding
                                                             error:&error];
            NSData *jsonData = [content dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *customizations =
                [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&error]
                    [@"customizations"];
            NSMutableArray *identifiers = [NSMutableArray arrayWithCapacity:1];

            NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
            [fetchRequest
                setEntity:[NSEntityDescription entityForName:@"Customization"
                                      inManagedObjectContext:[self getManagedObjectContext]]];
            NSArray *existingCustomizations =
                [[self getManagedObjectContext] executeFetchRequest:fetchRequest error:&error];

            for (Customization *customization in existingCustomizations) {
                [identifiers addObject:[NSString stringWithFormat:@"%@%@", customization.type,
                                                                  customization.name]];
            }

            for (NSDictionary *data in customizations) {
                if ([identifiers containsObject:[NSString stringWithFormat:@"%@%@", data[@"type"],
                                                                           data[@"name"]]]) {
                    continue;
                }
                Customization *customization = [NSEntityDescription
                    insertNewObjectForEntityForName:@"Customization"
                             inManagedObjectContext:[self getManagedObjectContext]];
                customization.name = data[@"name"];
                customization.text = data[@"text"];
                customization.notes = data[@"notes"];
                customization.type = data[@"type"];
                customization.group = data[@"group"];
                if (data[@"set"]) {
                    customization.set = data[@"set"];
                }
                customization.price = data[@"price"];
                customization.purchasable = data[@"purchasable"];
            }

            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            [defaults setObject:[NSDate date] forKey:@"lastContentFetch"];
            [defaults synchronize];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)fetchTasks:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] getObjectsAtPath:@"tasks/user"
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            [defaults setObject:[NSDate date] forKey:@"lastTaskFetch"];
            [defaults synchronize];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)fetchCompletedTasks:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager]
     getObjectsAtPath:@"tasks/user?type=completedTodos"
     parameters:nil
     success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
         NSError *executeError = nil;
         [[self getManagedObjectContext] saveToPersistentStore:&executeError];
         [defaults setObject:[NSDate date] forKey:@"lastTaskFetch"];
         [defaults synchronize];
         if (successBlock) {
             successBlock();
         }
         [self.networkIndicatorController endNetworking];
         return;
     }
     failure:^(RKObjectRequestOperation *operation, NSError *error) {
         if (errorBlock) {
             errorBlock();
         }
         [self.networkIndicatorController endNetworking];
         return;
     }];
}

- (void)fetchUser:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self fetchUser:YES onSuccess:successBlock onError:errorBlock];
}

- (void)fetchUser:(BOOL)includeTasks
        onSuccess:(void (^)())successBlock
          onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] getObjectsAtPath:@"user"
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            User *fetchedUser = [mappingResult dictionary][@"data"];
            if ([fetchedUser isKindOfClass:User.class]) {
                if (![currentUser isEqualToString:self.user.id]) {
                    NSFetchRequest *fetchRequest =
                        [NSFetchRequest fetchRequestWithEntityName:@"User"];
                    [fetchRequest setReturnsObjectsAsFaults:NO];
                    NSPredicate *predicate =
                        [NSPredicate predicateWithFormat:@"id==%@", fetchedUser.id];
                    [fetchRequest setPredicate:predicate];
                    NSError *error;
                    NSArray *fetchedObjects =
                        [[self getManagedObjectContext] executeFetchRequest:fetchRequest
                                                                      error:&error];
                    if ([fetchedObjects count] > 0) {
                        self.user = fetchedObjects[0];
                    }

                    [[NSNotificationCenter defaultCenter] postNotificationName:@"userChanged"
                                                                        object:nil];
                }
            }
            [self setTimezoneOffset];
            if (![[defaults stringForKey:@"contentLanguage"]
                    isEqualToString:self.user.preferences.language]) {
                [self fetchContent:nil onError:nil];
            }
            if ([defaults stringForKey:@"PushNotificationDeviceToken"]) {
                NSString *token = [defaults stringForKey:@"PushNotificationDeviceToken"];
                bool addDevice = YES;
                for (PushDevice *device in fetchedUser.pushDevices) {
                    if ([device.regId isEqualToString:token]) {
                        addDevice = NO;
                        break;
                    }
                }
                if (addDevice) {
                    [self addPushDevice:token onSuccess:nil onError:nil];
                }
            }
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            [defaults setObject:[NSDate date] forKey:@"lastTaskFetch"];
            [defaults synchronize];
            if (includeTasks) {
                [self fetchTasks:successBlock onError:errorBlock];
            } else {
                if (successBlock) {
                    successBlock();
                }
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)updateUser:(NSDictionary *)newValues
         onSuccess:(void (^)())successBlock
           onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] putObject:nil
        path:@"user"
        parameters:newValues
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            // TODO: API currently does not return maxHealth, maxMP and toNextLevel. To set them to
            // correct values, fetch again until this is fixed.
            [self fetchUser:^() {
                NSError *executeError = nil;
                [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                if (successBlock) {
                    successBlock();
                }
            }
                onError:nil];
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)changeClass:(NSString *)newClass
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSString *url;
    if (newClass) {
        url = [NSString stringWithFormat:@"user/change-class?class=%@", newClass];
    } else {
        url = @"user/change-class";
    }

    [[RKObjectManager sharedManager] postObject:nil
        path:url
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)disableClasses:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    [[RKObjectManager sharedManager] postObject:nil
                                           path:@"user/disable-classes"
                                     parameters:nil
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            if (successBlock) {
                                                successBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)fetchGroup:(NSString *)groupID
         onSuccess:(void (^)())successBlock
           onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager]
        getObjectsAtPath:[NSString stringWithFormat:@"groups/%@", groupID]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            if ([groupID isEqualToString:@"party"]) {
                Group *party = [mappingResult dictionary][@"data"];
                if ([party isKindOfClass:[NSArray class]]) {
                    NSArray *array = (NSArray *)party;
                    if (array.count > 0) {
                        party = array[0];
                    }
                }
                if (party && [party.type isEqualToString:@"party"] &&
                    ![party.id isEqualToString:[self getUser].partyID]) {
                    [self getUser].partyID = party.id;
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"partyChanged"
                                                                        object:party];
                }
            }
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            if ([groupID isEqualToString:@"party"]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"partyUpdated"
                                                                    object:nil];
            }
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (errorBlock) {
                errorBlock();
            }
            if (operation.HTTPRequestOperation.response.statusCode == 200) {
                [self fetchGroups:@"party"
                    onSuccess:nil onError:nil];
                return;
            }
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }

            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)fetchGroups:(NSString *)groupType
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSDictionary *params = @{ @"type" : groupType };
    [[RKObjectManager sharedManager] getObjectsAtPath:@"groups"
        parameters:params
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            if ([groupType isEqualToString:@"party"]) {
                Group *party = (Group *)[mappingResult dictionary][@"data"];
                [self getUser].partyID = party.id;
                [[NSNotificationCenter defaultCenter] postNotificationName:@"partyChanged"
                                                                    object:party];
            } else if ([groupType isEqualToString:@"guilds"]) {
                NSArray *guilds = [mappingResult array];
                for (Group *guild in guilds) {
                    guild.type = @"guild";
                    guild.isMember = @YES;
                }
            } else if ([groupType isEqualToString:@"publicGuilds"]) {
                NSArray *guilds = [mappingResult array];
                for (Group *guild in guilds) {
                    guild.type = @"guild";
                }
            }
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)fetchMember:(NSString *)memberId
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] getObjectsAtPath:[@"members/" stringByAppendingString:memberId]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)upDownTask:(Task *)task
         direction:(NSString *)withDirection
         onSuccess:(void (^)(NSArray *valuesArray))successBlock
           onError:(void (^)())errorBlock {
    if (task.id == nil || [task.id isEqualToString:@""]) {
        // Task is not saved on the server yet. Sending a request now would create a new empty
        // habit.
        return;
    }

    [self.networkIndicatorController beginNetworking];

    id<GAITracker> tracker = [[GAI sharedInstance] defaultTracker];
    [tracker send:[[GAIDictionaryBuilder createEventWithCategory:@"behaviour"
                                                          action:@"score task"
                                                           label:nil
                                                           value:nil] build]];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"tasks/%@/score/%@", task.id, withDirection]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            HRPGTaskResponse *taskResponse = (HRPGTaskResponse *)[mappingResult dictionary][@"data"];

            if ([task.managedObjectContext existingObjectWithID:task.objectID
                                                          error:&executeError] != nil) {
                task.value = @([task.value floatValue] + [taskResponse.delta floatValue]);
            }
            if ([self.user.level integerValue] < [taskResponse.level integerValue]) {
                self.user.level = taskResponse.level;
                [self displayLevelUpNotification];
                // Set experience to the amount, that was missing for the next level. So that the
                // notification
                // displays the correct amount of experience gained
                self.user.experience =
                    @([self.user.experience floatValue] - [self.user.nextLevel floatValue]);
            }
            self.user.level = taskResponse.level ? taskResponse.level : self.user.level;

            NSNumber *expDiff =
                @([taskResponse.experience floatValue] - [self.user.experience floatValue]);
            self.user.experience = taskResponse.experience;
            NSNumber *healthDiff =
                @([taskResponse.health floatValue] - [self.user.health floatValue]);
            self.user.health = taskResponse.health ? taskResponse.health : self.user.health;
            NSNumber *magicDiff = @([taskResponse.magic floatValue] - [self.user.magic floatValue]);
            self.user.magic = taskResponse.magic ? taskResponse.magic : self.user.magic;

            NSNumber *goldDiff = @([taskResponse.gold floatValue] - [self.user.gold floatValue]);
            self.user.gold = taskResponse.gold ? taskResponse.gold : self.user.gold;

            [self displayTaskSuccessNotification:healthDiff
                              withExperienceDiff:expDiff
                                    withGoldDiff:goldDiff
                                   withMagicDiff:magicDiff];
            if ([task.type isEqual:@"daily"] || [task.type isEqual:@"todo"]) {
                task.completed = @([withDirection isEqual:@"up"]);
            }

            if ([task.type isEqual:@"daily"]) {
                if ([withDirection isEqualToString:@"up"]) {
                    task.streak = @([task.streak integerValue] + 1);
                } else if ([task.streak integerValue] > 0) {
                    task.streak = @([task.streak integerValue] - 1);
                }
            }

            if (self.user && self.user.health && [self.user.health floatValue] <= 0) {
                HRPGDeathView *deathView = [[HRPGDeathView alloc] init];
                [deathView show];
            }

            if (taskResponse.dropKey) {
                id<GAITracker> tracker = [[GAI sharedInstance] defaultTracker];
                [tracker send:[[GAIDictionaryBuilder createEventWithCategory:@"behaviour"
                                                                      action:@"acquire item"
                                                                       label:nil
                                                                       value:nil] build]];

                NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
                // Edit the entity name as appropriate.
                NSEntityDescription *entity =
                    [NSEntityDescription entityForName:@"Item"
                                inManagedObjectContext:[self getManagedObjectContext]];
                [fetchRequest setEntity:entity];
                NSPredicate *predicate;
                predicate =
                    [NSPredicate predicateWithFormat:@"type==%@ || key==%@", taskResponse.dropType,
                                                     taskResponse.dropKey];
                [fetchRequest setPredicate:predicate];
                NSError *error = nil;
                NSArray *fetchedObjects =
                    [[self getManagedObjectContext] executeFetchRequest:fetchRequest error:&error];
                if ([fetchedObjects count] == 1) {
                    Item *droppedItem = fetchedObjects[0];
                    droppedItem.owned = @([droppedItem.owned integerValue] + 1);
                    [self displayDropNotification:droppedItem.key
                                         withName:droppedItem.text
                                         withType:taskResponse.dropType
                                         withNote:taskResponse.dropNote];
                }
            }
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            NSNumber *nextLevel;
            if (self.user.nextLevel) {
                nextLevel = self.user.nextLevel;
            } else {
                nextLevel = @0;
            }
            if (successBlock) {
                successBlock(@[
                    healthDiff, expDiff, self.user.gold, self.user.health, self.user.experience,
                    nextLevel, magicDiff
                ]);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)scoreChecklistItem:(Task *)task checklistItem:(ChecklistItem *)item onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    [[RKObjectManager sharedManager]
     postObject:nil
     path:[NSString stringWithFormat:@"tasks/%@/checklist/%@/score", task.id, item.id]
     parameters:nil
     success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
         if (successBlock) {
             successBlock();
         }
         [self.networkIndicatorController endNetworking];
         return;
     }
     failure:^(RKObjectRequestOperation *operation, NSError *error) {
         if (operation.HTTPRequestOperation.response.statusCode == 503) {
             [self displayServerError];
         } else {
             [self displayNetworkError];
         }
         if (errorBlock) {
             errorBlock();
         }
         [self.networkIndicatorController endNetworking];
         return;
     }];}

- (void)getReward:(NSString *)rewardID
        onSuccess:(void (^)())successBlock
          onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"tasks/%@/score/down", rewardID]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            HRPGTaskResponse *taskResponse = (HRPGTaskResponse *)[mappingResult dictionary][@"data"];
            if ([self.user.level integerValue] < [taskResponse.level integerValue]) {
                [self displayLevelUpNotification];
                // Set experience to the amount, that was missing for the next level. So that the
                // notification
                // displays the correct amount of experience gained
                self.user.experience =
                    @([self.user.experience floatValue] - [self.user.nextLevel floatValue]);
            }
            self.user.level = taskResponse.level ? taskResponse.level : self.user.level;
            self.user.experience = taskResponse.experience ? taskResponse.experience : self.user.experience;
            self.user.health = taskResponse.health ? taskResponse.health : self.user.experience;
            self.user.magic = taskResponse.magic ? taskResponse.magic : self.user.magic;

            NSNumber *goldDiff = @([taskResponse.gold floatValue] - [self.user.gold floatValue]);
            self.user.gold = taskResponse.gold;
            [self displayRewardNotification:goldDiff];
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)createTask:(Task *)task onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:task
        path:nil
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)createTasks:(NSArray *)tasks onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] postObject:nil
                                           path:@"tasks/user"
                                     parameters:tasks
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            NSError *executeError = nil;
                                            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                                            if (successBlock) {
                                                successBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)updateTask:(Task *)task onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] putObject:task
        path:nil
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)deleteTask:(Task *)task onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] deleteObject:task
        path:[NSString stringWithFormat:@"tasks/%@", task.id]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)createReward:(Reward *)reward
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:reward
        path:nil
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)updateReward:(Reward *)reward
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] putObject:reward
        path:nil
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)deleteReward:(Reward *)reward
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] deleteObject:reward
        path:[NSString stringWithFormat:@"tasks/%@", reward.key]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)fetchBuyableRewards:(void (^)())successBlock onError:(void (^)())errorBlock {
    [[RKObjectManager sharedManager] getObjectsAtPath:@"user/inventory/buy"
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;

            NSFetchRequest *fetch = [[NSFetchRequest alloc] init];
            NSEntityDescription *entity =
                [NSEntityDescription entityForName:@"Gear"
                            inManagedObjectContext:[self getManagedObjectContext]];
            [fetch setEntity:entity];
            [fetch setPredicate:[NSPredicate predicateWithFormat:@"buyable == true"]];
            NSMutableArray *oldBuyableGear =
                [[[self getManagedObjectContext] executeFetchRequest:fetch error:&executeError]
                    mutableCopy];
            NSArray *buyableGear = [mappingResult array];
            for (Gear *gear in buyableGear) {
                if (![gear.buyable boolValue]) {
                    gear.buyable = @YES;
                }
                if ([oldBuyableGear containsObject:gear]) {
                    [oldBuyableGear removeObject:gear];
                }
            }
            for (Gear *gear in oldBuyableGear) {
                gear.buyable = @NO;
            }

            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)clearCompletedTasks:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:@"tasks/clear-completed"
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)loginUser:(NSString *)username
     withPassword:(NSString *)password
        onSuccess:(void (^)())successBlock
          onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSDictionary *params = @{ @"username" : username, @"password" : password };
    [[RKObjectManager sharedManager] postObject:Nil
        path:@"user/auth/local/login"
        parameters:params
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            HRPGLoginData *loginData = (HRPGLoginData *)[mappingResult dictionary][@"data"];
            PDKeychainBindings *keyChain = [PDKeychainBindings sharedKeychainBindings];
            [keyChain setString:loginData.id forKey:@"id"];
            [keyChain setString:loginData.key forKey:@"key"];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"userChanged" object:nil];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)loginUserSocial:(NSString *)userID
        withAccessToken:(NSString *)accessToken
              onSuccess:(void (^)())successBlock
                onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSDictionary *params = @{
        @"network" : @"facebook",
        @"authResponse" : @{@"access_token" : accessToken, @"client_id" : userID}
    };
    [[RKObjectManager sharedManager] postObject:Nil
        path:@"user/auth/social"
        parameters:params
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            HRPGLoginData *loginData = (HRPGLoginData *)[mappingResult dictionary][@"data"];
            PDKeychainBindings *keyChain = [PDKeychainBindings sharedKeychainBindings];
            [keyChain setString:loginData.id forKey:@"id"];
            [keyChain setString:loginData.key forKey:@"key"];

            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)registerUser:(NSString *)username
        withPassword:(NSString *)password
           withEmail:(NSString *)email
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSDictionary *params = @{
        @"username" : username,
        @"password" : password,
        @"confirmPassword" : password,
        @"email" : email
    };
    [[RKObjectManager sharedManager] postObject:Nil
        path:@"user/auth/local/register"
        parameters:params
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            [self loginUser:username
                withPassword:password
                onSuccess:^() {
                    if (successBlock) {
                        successBlock();
                    }
                }
                onError:nil];

            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                if (errorBlock) {
                    errorBlock(errorMessage.errorMessage);
                }
            } else {
                [self displayNetworkError];
            }

            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)sleepInn:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:Nil
        path:@"user/sleep"
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            self.user.preferences.sleep = @(![self.user.preferences.sleep boolValue]);
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)reviveUser:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:Nil
        path:@"user/revive"
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            [self fetchUser:^{
                if (successBlock) {
                    successBlock();
                }
            } onError:^{
                if (successBlock) {
                    successBlock();
                }
            }];
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                [self fetchUser:^{
                    if (successBlock) {
                        successBlock();
                    }
                } onError:^{
                    if (errorBlock) {
                        errorBlock();
                    }
                }];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)buyObject:(MetaReward *)reward
        onSuccess:(void (^)())successBlock
          onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:Nil
        path:[NSString stringWithFormat:@"user/buy/%@", reward.key]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            HRPGUserBuyResponse *response = [mappingResult dictionary][@"data"];
            self.user.health = response.health ? response.health : self.user.health;
            NSNumber *goldDiff;
            if (response.gold) {
                goldDiff = @([response.gold floatValue] - [self.user.gold floatValue]);
                self.user.gold = response.gold;
            } else {
                goldDiff = reward.value;
                self.user.gold = [NSNumber numberWithFloat:[self.user.gold floatValue] - [goldDiff floatValue]];
            }
            if (response.experience) {
                self.user.experience = response.experience;
            } else {
                if ([response.armoireType isEqualToString:@"experience"]) {
                    self.user.experience = [NSNumber numberWithFloat:[self.user.experience floatValue] + [response.armoireValue floatValue]];
                }
            }
            self.user.magic = response.magic ? response.magic : self.user.magic;
            self.user.equipped.armor = response.equippedArmor ? response.equippedArmor : self.user.equipped.armor;
            self.user.equipped.back = response.equippedBack ? response.equippedBack : self.user.equipped.back;
            self.user.equipped.head = response.equippedHead ? response.equippedHead : self.user.equipped.head;
            self.user.equipped.headAccessory = response.equippedHeadAccessory ? response.equippedHeadAccessory : self.user.equipped.headAccessory;
            self.user.equipped.shield = response.equippedShield ? response.equippedShield : self.user.equipped.shield;
            self.user.equipped.weapon = response.equippedWeapon ? response.equippedWeapon : self.user.equipped.weapon;
            if ([reward isKindOfClass:[Gear class]]) {
                Gear *gear = (Gear *)reward;
                gear.owned = YES;
            }
            
            if (response.armoireType) {
                HRPGResponseMessage *message = [mappingResult dictionary][[NSNull null]];
                [self displayArmoireNotification:response.armoireType
                                         withKey:response.armoireKey
                                        withText:message.message
                                       withValue:response.armoireValue];
            } else {
                [self displayRewardNotification:goldDiff];
            }
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)unlockPath:(NSString *)path
         onSuccess:(void (^)())successBlock
           onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"user/unlock?path=%@", path]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            [self fetchUser:^() {
                if (successBlock) {
                    successBlock();
                }
            }
                onError:nil];
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 401) {
                [self displayNoGemAlert];
            } else if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)sellItem:(Item *)item onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:Nil
        path:[NSString stringWithFormat:@"user/sell/%@/%@", item.type, item.key]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            HRPGUserBuyResponse *response = [mappingResult dictionary][@"data"];
            self.user.health = response.health ? response.health : self.user.health;
            self.user.gold = response.gold ? response.health : self.user.gold;
            self.user.magic = response.magic ? response.health : self.user.magic;
            self.user.equipped.armor = response.equippedArmor ? response.equippedArmor : self.user.equipped.armor;
            self.user.equipped.back = response.equippedBack ? response.equippedBack : self.user.equipped.back;
            self.user.equipped.head = response.equippedHead ? response.equippedHead : self.user.equipped.head;
            self.user.equipped.headAccessory = response.equippedHeadAccessory ? response.equippedHeadAccessory : self.user.equipped.headAccessory;
            self.user.equipped.shield = response.equippedShield ? response.equippedShield : self.user.equipped.shield;
            self.user.equipped.weapon = response.equippedWeapon ? response.equippedWeapon : self.user.equipped.weapon;
            item.owned = @([item.owned intValue] - 1);
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)equipObject:(NSString *)key
           withType:(NSString *)type
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:Nil
        path:[NSString stringWithFormat:@"user/equip/%@/%@", type, key]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            HRPGUserBuyResponse *response = [mappingResult dictionary][@"data"];
            self.user.equipped.headAccessory = response.equippedHeadAccessory;
            self.user.equipped.armor = response.equippedArmor;
            self.user.equipped.back = response.equippedBack;
            self.user.equipped.body = response.equippedBody;
            self.user.equipped.eyewear = response.equippedEyewear;
            self.user.equipped.head = response.equippedHead;
            self.user.equipped.shield = response.equippedShield;
            self.user.equipped.weapon = response.equippedWeapon;
            self.user.costume.armor = response.costumeArmor;
            self.user.costume.back = response.costumeBack;
            self.user.costume.body = response.costumeBody;
            self.user.costume.eyewear = response.costumeEyewear;
            self.user.costume.head = response.costumeHead;
            self.user.costume.headAccessory = response.costumeHeadAccessory;
            self.user.costume.shield = response.costumeShield;
            self.user.costume.weapon = response.costumeWeapon;
            self.user.currentMount = response.currentMount;
            self.user.currentPet = response.currentPet;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)hatchEgg:(NSString *)egg withPotion:(NSString *)hPotion onSuccess:(void (^)(NSString *))successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:Nil
        path:[NSString stringWithFormat:@"user/hatch/%@/%@", egg, hPotion]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            HRPGUserBuyResponse *response = [mappingResult dictionary][@"data"];
            self.user.equipped.headAccessory = response.equippedHeadAccessory;
            self.user.equipped.armor = response.equippedArmor;
            self.user.equipped.back = response.equippedBack;
            self.user.equipped.body = response.equippedBody;
            self.user.equipped.eyewear = response.equippedEyewear;
            self.user.equipped.head = response.equippedHead;
            self.user.equipped.shield = response.equippedShield;
            self.user.equipped.weapon = response.equippedWeapon;
            self.user.costume.armor = response.costumeArmor;
            self.user.costume.back = response.costumeBack;
            self.user.costume.body = response.costumeBody;
            self.user.costume.eyewear = response.costumeEyewear;
            self.user.costume.head = response.costumeHead;
            self.user.costume.headAccessory = response.costumeHeadAccessory;
            self.user.costume.shield = response.costumeShield;
            self.user.costume.weapon = response.costumeWeapon;
            self.user.currentMount = response.currentMount;
            self.user.currentPet = response.currentPet;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            HRPGResponseMessage *message = [mappingResult dictionary][[NSNull null]];
            if (successBlock) {
                successBlock(message.message);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)castSpell:(NSString *)spell
    withTargetType:(NSString *)targetType
          onTarget:(NSString *)target
         onSuccess:(void (^)())successBlock
           onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSString *url = nil;
    CGFloat health = [self.user.health floatValue];
    CGFloat gold = [self.user.gold floatValue];
    NSInteger mana = [self.user.magic integerValue];
    if (target) {
        url = [NSString stringWithFormat:@"user/class/cast/%@?targetType=%@&targetId=%@", spell,
                                         targetType, target];
    } else {
        url = [NSString stringWithFormat:@"user/class/cast/%@?targetType=%@", spell, targetType];
    }
    [[RKObjectManager sharedManager] postObject:nil
        path:url
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            [self fetchUser:^() {
                NSError *executeError = nil;
                [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                [self displaySpellNotification:(mana - [self.user.magic integerValue])
                                withHealthDiff:([self.user.health floatValue] - health)
                                  withGoldDiff:([self.user.gold floatValue] - gold)];
                if (successBlock) {
                    successBlock();
                }
                [self.networkIndicatorController endNetworking];
                return;
            }
                    onError:nil];
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)acceptQuest:(NSString *)group
          onSuccess:(void (^)())successBlock
            onError:(void (^)(NSString * errorMessage))errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/quests/accept", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401 || operation.HTTPRequestOperation.response.statusCode == 400) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                NSString *errorMessage = @"";
                if (((NSArray *)[error userInfo][RKObjectMapperErrorObjectsKey]).count > 0) {
                    errorMessage = ((RKErrorMessage *)[error userInfo][RKObjectMapperErrorObjectsKey][0]).errorMessage;
                }
                errorBlock(errorMessage);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)chatSeen:(NSString *)group {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/chat/seen", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            [self.networkIndicatorController endNetworking];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"partyUpdated" object:nil];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)markInboxSeen:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] postObject:nil
                                           path:@"user/mark-pms-read"
                                     parameters:nil
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            [self getUser].inboxNewMessages = 0;
                                            NSError *executeError = nil;
                                            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                                            [self.networkIndicatorController endNetworking];
                                            if (successBlock) {
                                                successBlock();
                                            }
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            return;
                                        }];
}

- (void)rejectQuest:(NSString *)group
          onSuccess:(void (^)())successBlock
            onError:(void (^)(NSString *errorMessage))errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/quests/reject", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401 || operation.HTTPRequestOperation.response.statusCode == 400) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                NSString *errorMessage = @"";
                if (((NSArray *)[error userInfo][RKObjectMapperErrorObjectsKey]).count > 0) {
                    errorMessage = ((RKErrorMessage *)[error userInfo][RKObjectMapperErrorObjectsKey][0]).errorMessage;
                }
                errorBlock(errorMessage);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)abortQuest:(NSString *)group
         onSuccess:(void (^)())successBlock
           onError:(void (^)(NSString *errorMessage))errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/quests/abort", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401 || operation.HTTPRequestOperation.response.statusCode == 400) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                NSString *errorMessage = @"";
                if (((NSArray *)[error userInfo][RKObjectMapperErrorObjectsKey]).count > 0) {
                    errorMessage = ((RKErrorMessage *)[error userInfo][RKObjectMapperErrorObjectsKey][0]).errorMessage;
                }
                errorBlock(errorMessage);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)cancelQuest:(NSString *)group
          onSuccess:(void (^)())successBlock
            onError:(void (^)(NSString *errorMessage))errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/quests/cancel", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401 || operation.HTTPRequestOperation.response.statusCode == 400) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                NSString *errorMessage = @"";
                if (((NSArray *)[error userInfo][RKObjectMapperErrorObjectsKey]).count > 0) {
                    errorMessage = ((RKErrorMessage *)[error userInfo][RKObjectMapperErrorObjectsKey][0]).errorMessage;
                }
                errorBlock(errorMessage);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)forceStartQuest:(NSString *)group
              onSuccess:(void (^)())successBlock
                onError:(void (^)(NSString *errorMessage))errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/quests/force-start", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401 || operation.HTTPRequestOperation.response.statusCode == 400) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                NSString *errorMessage = @"";
                if (((NSArray *)[error userInfo][RKObjectMapperErrorObjectsKey]).count > 0) {
                    errorMessage = ((RKErrorMessage *)[error userInfo][RKObjectMapperErrorObjectsKey][0]).errorMessage;
                }
                errorBlock(errorMessage);
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)inviteToQuest:(NSString *)group
            withQuest:(Quest *)quest
            onSuccess:(void (^)())successBlock
              onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/quests/invite/%@", group, quest.key]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            if (quest) {
                quest.owned = @([quest.owned intValue] - 1);
            }
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Invitation Error"
                                                                message:error.localizedDescription
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)createGroup:(Group *)group
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:group
        path:nil
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;

            if ([group.type isEqualToString:@"party"]) {
                Group *party = [mappingResult dictionary][@"data"];
                [self getUser].partyID = party.id;
            }

            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)updateGroup:(Group *)group
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] putObject:group
        path:[NSString stringWithFormat:@"groups/%@", group.id]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)inviteMembers:(NSArray *)members
    withInvitationType:(NSString *)invitationType
         toGroupWithID:(NSString *)group
             onSuccess:(void (^)())successBlock
               onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/invite", group]
        parameters:@{
            invitationType : members,
            @"inviter" : self.user.username
        }
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 400 || operation.HTTPRequestOperation.response.statusCode == 404 || operation.HTTPRequestOperation.response.statusCode == 401) {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Invitation Error", nil)
                                                                message:error.localizedDescription
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)joinGroup:(NSString *)group
         withType:(NSString *)type
        onSuccess:(void (^)())successBlock
          onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/join", group]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            Group *group = [mappingResult dictionary][@"data"];
            if ([type isEqualToString:@"party"]) {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                if (![group.id isEqualToString:[defaults stringForKey:@"partyID"]]) {
                    [defaults setObject:group.id forKey:@"partyID"];
                    [defaults synchronize];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"partyChanged"
                                                                        object:group];
                }
            }
            group.isMember = @YES;

            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)leaveGroup:(Group *)group
          withType:(NSString *)type
         onSuccess:(void (^)())successBlock
           onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/leave", group.id]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            if ([type isEqualToString:@"party"]) {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setObject:nil forKey:@"partyID"];
                [defaults synchronize];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"partyChanged"
                                                                    object:group];
            }
            group.isMember = @NO;

            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)fetchGroupMembers:(NSString *)groupID
         withPublicFields:(BOOL)withPublicFields
                 fetchAll:(BOOL)fetchAll
                onSuccess:(void (^)())successBlock
                  onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    if (withPublicFields) {
        parameters[@"includeAllPublicFields"] = @"true";
    }

    [[RKObjectManager sharedManager] getObject:nil
        path:[NSString stringWithFormat:@"groups/%@/members", groupID]
        parameters:parameters
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)chatMessage:(NSString *)message
          withGroup:(NSString *)groupID
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/chat", groupID]
        parameters:@{
            @"message" : message
        }
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:@"newChatMessage"
                                                                object:groupID];
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)privateMessage:(NSString *)message toUserWithID:(NSString *)userID onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] postObject:nil
                                           path:@"members/send-private-message"
                                     parameters:@{
                                                  @"message" : message,
                                                  @"toUserId" : userID
                                                  }
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            [self fetchUser:successBlock onError:errorBlock];
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)deleteMessage:(ChatMessage *)message
            withGroup:(NSString *)groupID
            onSuccess:(void (^)())successBlock
              onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] deleteObject:message
        path:[NSString stringWithFormat:@"groups/%@/chat/%@", groupID, message.id]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)deletePrivateMessage:(InboxMessage *)message
            onSuccess:(void (^)())successBlock
              onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] deleteObject:message
                                             path:[NSString stringWithFormat:@"user/messages/%@", message.id]
                                       parameters:nil
                                          success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                              NSError *executeError = nil;
                                              [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                                              if (successBlock) {
                                                  successBlock();
                                              }
                                              [self.networkIndicatorController endNetworking];
                                              return;
                                          }
                                          failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                              if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                  [self displayServerError];
                                              } else {
                                                  [self displayNetworkError];
                                              }
                                              if (errorBlock) {
                                                  errorBlock();
                                              }
                                              [self.networkIndicatorController endNetworking];
                                              return;
                                          }];
}

- (void)likeMessage:(ChatMessage *)message
          withGroup:(NSString *)groupID
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/chat/%@/like", groupID, message.id]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)flagMessage:(ChatMessage *)message
          withGroup:(NSString *)groupID
          onSuccess:(void (^)())successBlock
            onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"groups/%@/chat/%@/flag", groupID, message.id]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSError *executeError = nil;
            //[self.managedObjectContext deleteObject:message];
            [[self getManagedObjectContext] saveToPersistentStore:&executeError];
            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)feedPet:(Pet *)pet
       withFood:(Food *)food
      onSuccess:(void (^)())successBlock
        onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"user/feed/%@/%@", pet.key, food.key]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            NSDictionary *result = [mappingResult dictionary][@"data"];
            NSNumber *petStatus = result[@"value"];

            NSError *executeError = nil;
            pet.trained = petStatus;
            food.owned = @([food.owned integerValue] - 1);
            [[self managedObjectContext] saveToPersistentStore:&executeError];

            NSString *preferenceString;
            if ([pet likesFood:food]) {
                preferenceString = NSLocalizedString(@"Your pet really likes the %@", nil);
            } else {
                preferenceString =
                    NSLocalizedString(@"Your pet eats the %@ but doesn't seem to enjoy it.", nil);
            }
            NSDictionary *options = @{
                kCRToastTextKey : [NSString stringWithFormat:preferenceString, food.text],
                kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
                kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
                kCRToastBackgroundColorKey : [UIColor yellow10],
            };
            [CRToastManager showNotificationWithOptions:options
                                        completionBlock:^{
                                        }];
            if ([result[@"value"] integerValue] == -1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self displayMountRaisedNotification:pet];
                });
                [self fetchUser:nil onError:nil];
            }

            if (successBlock) {
                successBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;

        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (!operation.HTTPRequestOperation.response ||
                operation.HTTPRequestOperation.response.statusCode == 502 ||
                operation.HTTPRequestOperation.response.statusCode == 503) {
                [self fetchUser:^() {
                    NSError *executeError = nil;
                    [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                    if (successBlock) {
                        successBlock();
                    }
                    [self.networkIndicatorController endNetworking];
                    return;
                }
                        onError:nil];
                return;
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)purchaseGems:(NSDictionary *)receipt
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    id<GAITracker> tracker = [[GAI sharedInstance] defaultTracker];
    [tracker send:[[GAIDictionaryBuilder createEventWithCategory:@"behaviour"
                                                          action:@"purchase gems"
                                                           label:nil
                                                           value:nil] build]];

    [[RKObjectManager sharedManager] postObject:nil
        path:@"iap/ios/verify"
        parameters:receipt
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            [self fetchUser:^() {
                NSError *executeError = nil;
                [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                 if (successBlock) {
                     successBlock();
                 }
                [self.networkIndicatorController endNetworking];
                return;
            }
                    onError:nil];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)purchaseItem:(NSString *)itemName
            fromType:(NSString *)itemType
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];

    [[RKObjectManager sharedManager] postObject:nil
        path:[NSString stringWithFormat:@"user/purchase/%@/%@", itemType, itemName]
        parameters:nil
        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
            [self fetchUser:^() {
                NSError *executeError = nil;
                [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                if (successBlock) {
                    successBlock();
                }
                [self.networkIndicatorController endNetworking];
                return;
            }
                    onError:nil];
            return;
        }
        failure:^(RKObjectRequestOperation *operation, NSError *error) {
            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                [self displayServerError];
            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                [self displayError:errorMessage.errorMessage];
            } else {
                [self displayNetworkError];
            }
            if (errorBlock) {
                errorBlock();
            }
            [self.networkIndicatorController endNetworking];
            return;
        }];
}

- (void)purchaseHourglassItem:(NSString *)itemName
            fromType:(NSString *)itemType
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] postObject:nil
                                           path:[NSString stringWithFormat:@"user/purchase-hourglass/%@/%@", itemType, itemName]
                                     parameters:nil
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            [self fetchUser:^() {
                                                NSError *executeError = nil;
                                                [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                                                if (successBlock) {
                                                    successBlock();
                                                }
                                                [self.networkIndicatorController endNetworking];
                                                return;
                                            }
                                                    onError:nil];
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                                                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                                                [self displayError:errorMessage.errorMessage];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)purchaseMysterySet:(NSString *)key
                    onSuccess:(void (^)())successBlock
                      onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] postObject:nil
                                           path:[NSString stringWithFormat:@"user/buy-mystery-set/%@", key]
                                     parameters:nil
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            [self fetchUser:^() {
                                                NSError *executeError = nil;
                                                [[self getManagedObjectContext] saveToPersistentStore:&executeError];
                                                if (successBlock) {
                                                    successBlock();
                                                }
                                                [self.networkIndicatorController endNetworking];
                                                return;
                                            }
                                                    onError:nil];
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else if (operation.HTTPRequestOperation.response.statusCode == 401) {
                                                RKErrorMessage *errorMessage = [error userInfo][RKObjectMapperErrorObjectsKey][0];
                                                [self displayError:errorMessage.errorMessage];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)addPushDevice:(NSString *)token
           onSuccess:(void (^)())successBlock
             onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    [[RKObjectManager sharedManager] postObject:nil
                                           path:@"user/push-devices"
                                     parameters:@{
                                                  @"regId": token,
                                                  @"type": @"ios"
                                                  }
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)removePushDevice:(void (^)())successBlock
              onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    if ([defaults stringForKey:@"PushNotificationDeviceToken"]) {
        NSString *token = [defaults stringForKey:@"PushNotificationDeviceToken"];
        [defaults removeObjectForKey:@"PushNotificationDeviceToken"];
    
        [[RKObjectManager sharedManager] deleteObject:nil
                                           path:[@"user/push-devices/" stringByAppendingString:token]
                                     parameters:nil
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            if (successBlock) {
                                                successBlock();
                                            }
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
    }
}

- (void)fetchShopInventory:(NSString *)shopInventory onSuccess:(void (^)())successBlock onError:(void (^)())errorBlock {
    [self.networkIndicatorController beginNetworking];
    
    NSString *url = @"shops/";
    if ([shopInventory isEqualToString:MarketKey]) {
        url = [url stringByAppendingString:@"market"];
    } else if ([shopInventory isEqualToString:QuestsShopKey]) {
        url = [url stringByAppendingString:@"quests"];
    } else if ([shopInventory isEqualToString:SeasonalShopKey]) {
        url = [url stringByAppendingString:@"seasonal"];
    } else if ([shopInventory isEqualToString:TimeTravelersShopKey]) {
        url = [url stringByAppendingString:@"time-travelers"];
    } else {
        return;
    }
    [[RKObjectManager sharedManager] getObject:nil
                                           path:url
                                     parameters:nil
                                        success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
                                            [self.networkIndicatorController endNetworking];
                                            if (successBlock) {
                                                successBlock();
                                            }
                                            return;
                                        }
                                        failure:^(RKObjectRequestOperation *operation, NSError *error) {
                                            if (operation.HTTPRequestOperation.response.statusCode == 503) {
                                                [self displayServerError];
                                            } else {
                                                [self displayNetworkError];
                                            }
                                            if (errorBlock) {
                                                errorBlock();
                                            }
                                            [self.networkIndicatorController endNetworking];
                                            return;
                                        }];
}

- (void)displayNetworkError {
    NSDictionary *options = @{
        kCRToastTextKey : NSLocalizedString(@"Network error", nil),
        kCRToastSubtitleTextKey : NSLocalizedString(
            @"Couldn't connect to the server. Check your network connection", nil),
        kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastBackgroundColorKey : [UIColor red10],
        kCRToastImageKey : [self.iconFactory createImageForIcon:NIKFontAwesomeIconExclamationCircle]
    };
    [CRToastManager showNotificationWithOptions:options
                                completionBlock:^{
                                }];
}

- (void)displayServerError {
    NSDictionary *options = @{
        kCRToastTextKey : NSLocalizedString(@"Server error", nil),
        kCRToastSubtitleTextKey :
            NSLocalizedString(@"There seems to be a problem with the server. Try again later", nil),
        kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastBackgroundColorKey : [UIColor red10],
        kCRToastImageKey : [self.iconFactory createImageForIcon:NIKFontAwesomeIconExclamationCircle]
    };
    [CRToastManager showNotificationWithOptions:options
                                completionBlock:^{
                                }];
}

- (void)displayError:(NSString *)message {
    NSDictionary *options = @{
        kCRToastTextKey : message,
        kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastBackgroundColorKey : [UIColor red10],
        kCRToastImageKey : [self.iconFactory createImageForIcon:NIKFontAwesomeIconExclamationCircle]
    };
    [CRToastManager showNotificationWithOptions:options
                                completionBlock:^{
                                }];
}

- (void)displayTaskSuccessNotification:(NSNumber *)healthDiff
                    withExperienceDiff:(NSNumber *)expDiff
                          withGoldDiff:(NSNumber *)goldDiff
                         withMagicDiff:(NSNumber *)magicDiff {
    UIColor *notificationColor = [UIColor green10];
    NSString *content;
    if ([healthDiff intValue] < 0) {
        notificationColor = [UIColor red10];
        content = [NSString stringWithFormat:@"You lost %.1f health", [healthDiff floatValue] * -1];
        if ([[self getUser].level integerValue] >= 10 && [magicDiff floatValue] > 0) {
            content =
                [content stringByAppendingFormat:@" and %.1f mana", [magicDiff floatValue] * -1];
        }
    } else {
        content = [NSString stringWithFormat:@"You earned %ld experience and %.2f gold",
                                             (long)[expDiff integerValue], [goldDiff floatValue]];
        if ([[self getUser].level integerValue] >= 10 && [magicDiff floatValue] > 0) {
            content =
                [content stringByAppendingFormat:@" and gained %.1f mana", [magicDiff floatValue]];
        }
    }
    NSDictionary *options = @{
        kCRToastTextKey : content,
        kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastBackgroundColorKey : notificationColor,
        kCRToastImageKey : [self.iconFactory createImageForIcon:NIKFontAwesomeIconCheck]
    };
    [CRToastManager showNotificationWithOptions:options
                                completionBlock:^{
                                }];
}

- (void)displayArmoireNotification:(NSString *)type
                           withKey:(NSString *)key
                          withText:(NSString *)text
                         withValue:(NSNumber *)value {
    if ([type isEqualToString:@"experience"]) {
        NSDictionary *options = @{
            kCRToastTextKey : [text stringByStrippingHTML],
            kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
            kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
            kCRToastBackgroundColorKey : [UIColor yellow10],
            kCRToastImageKey :
                [self.iconFactory createImageForIcon:NIKFontAwesomeIconArrowCircleOUp]
        };
        [CRToastManager showNotificationWithOptions:options
                                    completionBlock:^{
                                    }];
    } else if ([type isEqualToString:@"food"]) {
        [self getImage:[NSString stringWithFormat:@"Pet_Food_%@", key]
            withFormat:@"png"
            onSuccess:^(UIImage *image) {
                UIColor *notificationColor = [UIColor blue10];
                NSDictionary *options = @{
                    kCRToastTextKey : [text stringByStrippingHTML],
                    kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
                    kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
                    kCRToastBackgroundColorKey : notificationColor,
                    kCRToastImageKey : image
                };
                [CRToastManager showNotificationWithOptions:options
                                            completionBlock:^{
                                            }];
            }
            onError:^(){

            }];
    } else if ([type isEqualToString:@"gear"]) {
        [self getImage:[NSString stringWithFormat:@"shop_%@", key]
            withFormat:@"png"
            onSuccess:^(UIImage *image) {
                UIColor *notificationColor = [UIColor green10];
                NSDictionary *options = @{
                    kCRToastTextKey : [text stringByStrippingHTML],
                    kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
                    kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
                    kCRToastBackgroundColorKey : notificationColor,
                    kCRToastImageKey : image
                };
                [CRToastManager showNotificationWithOptions:options
                                            completionBlock:^{
                                            }];
            }
            onError:^(){

            }];
    }
}

- (void)displayLevelUpNotification {
    [self fetchUser:nil onError:nil];
    
    if ([self.user.level integerValue] == 10 && ![self.user.preferences.disableClass boolValue]) {
        HRPGAppDelegate *del = (HRPGAppDelegate *)[UIApplication sharedApplication].delegate;
        UIViewController *activeViewController = del.window.rootViewController;UINavigationController *selectClassNavigationController =
        [del.window.rootViewController.storyboard
         instantiateViewControllerWithIdentifier:@"SelectClassNavigationController"];
        selectClassNavigationController.modalPresentationStyle = UIModalPresentationFullScreen;
        
        [activeViewController presentViewController:selectClassNavigationController
                                           animated:YES
                                         completion:^(){
                                             
                                         }];
    } else {
        NSArray *nibViews =
        [[NSBundle mainBundle] loadNibNamed:@"HRPGImageOverlayView" owner:self options:nil];
        HRPGImageOverlayView *overlayView = [nibViews objectAtIndex:0];
        overlayView.imageWidth = 140;
        overlayView.imageHeight = 147;
        [self.user setAvatarSubview:overlayView.imageView
                    showsBackground:YES
                         showsMount:YES
                           showsPet:YES];
        overlayView.titleText = NSLocalizedString(@"You gained a level!", nil);
        overlayView.descriptionText = [NSString
                                       stringWithFormat:
                                       NSLocalizedString(
                                                         @"By accomplishing your real-life goals, you've grown to Level %ld!", nil),
                                       (long)([self.user.level integerValue])];
        overlayView.dismissButtonText = NSLocalizedString(@"Huzzah!", nil);
        UIImageView *__weak weakAvatarView = overlayView.imageView;
        overlayView.shareAction = ^() {
            HRPGAppDelegate *del = (HRPGAppDelegate *)[UIApplication sharedApplication].delegate;
            UIViewController *activeViewController =
            del.window.rootViewController.presentedViewController;
            [HRPGSharingManager shareItems:@[
                                             [[NSString
                                               stringWithFormat:
                                               NSLocalizedString(
                                                                 @"I got to level %ld in Habitica by improving my real-life habits!",
                                                                 nil),
                                               (long)([self.user.level integerValue])]
                                              stringByAppendingString:@" https://habitica.com/social/level-up"],
                                             [HRPGSharingManager takeSnapshotOfView:weakAvatarView]
                                             ]
              withPresentingViewController:activeViewController
             withSourceView:nil];
        };
        [overlayView sizeToFit];
        
        KLCPopup *popup = [KLCPopup popupWithContentView:overlayView
                                                showType:KLCPopupShowTypeBounceIn
                                             dismissType:KLCPopupDismissTypeBounceOut
                                                maskType:KLCPopupMaskTypeDimmed
                                dismissOnBackgroundTouch:YES
                                   dismissOnContentTouch:NO];
        
        [popup show];
    }
}

- (void)displaySpellNotification:(NSInteger)manaDiff
                  withHealthDiff:(CGFloat)healthDiff
                    withGoldDiff:(CGFloat)goldDiff {
    UIColor *notificationColor = [UIColor red10];
    NSString *content;
    if (healthDiff > 0) {
        notificationColor = [UIColor green10];
        content = [NSString stringWithFormat:NSLocalizedString(@"Health: +%.1f\nMana: -%ld", nil),
                                             healthDiff, (long)manaDiff];
    } else if (goldDiff > 0) {
        notificationColor = [UIColor green10];
        content = [NSString stringWithFormat:NSLocalizedString(@"Gold: +%.1f\nMana: -%ld", nil),
                                             goldDiff, (long)manaDiff];
    } else {
        content = [NSString stringWithFormat:NSLocalizedString(@"Mana: -%ld", nil), (long)manaDiff];
    }
    NSDictionary *options = @{
        kCRToastTextKey : content,
        kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastBackgroundColorKey : notificationColor,
        kCRToastImageKey : [self.iconFactory createImageForIcon:NIKFontAwesomeIconCheck]
    };
    [CRToastManager showNotificationWithOptions:options
                                completionBlock:^{
                                }];
}

- (void)displayRewardNotification:(NSNumber *)goldDiff {
    UIColor *notificationColor = [UIColor yellow10];
    NSDictionary *options = @{
        kCRToastTextKey :
            [NSString stringWithFormat:NSLocalizedString(@"%.2f Gold", nil), [goldDiff floatValue]],
        kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
        kCRToastBackgroundColorKey : notificationColor,
        kCRToastImageKey : [self.iconFactory createImageForIcon:NIKFontAwesomeIconCheck]
    };
    [CRToastManager showNotificationWithOptions:options
                                completionBlock:^{
                                }];
}

- (void)displayDropNotification:(NSString *)key
                       withName:(NSString *)name
                       withType:(NSString *)type
                       withNote:(NSString *)note {
    NSString *description;
    if ([[type lowercaseString] isEqualToString:@"food"]) {
        description = [NSString stringWithFormat:@"You found %@!", name];
    } else {
        description = [NSString stringWithFormat:@"You found a %@ %@!", name, type];
    }
    [self getImage:[NSString stringWithFormat:@"Pet_%@_%@", type, key]
        withFormat:@"png"
        onSuccess:^(UIImage *image) {
            UIColor *notificationColor = [UIColor blue10];
            NSDictionary *options = @{
                kCRToastTextKey : description,
                kCRToastTextAlignmentKey : @(NSTextAlignmentLeft),
                kCRToastSubtitleTextAlignmentKey : @(NSTextAlignmentLeft),
                kCRToastBackgroundColorKey : notificationColor,
                kCRToastImageKey : image
            };
            [CRToastManager showNotificationWithOptions:options
                                        completionBlock:^{
                                        }];
        }
        onError:^(){

        }];
}

- (void)displayMountRaisedNotification:(Pet *)mount {
    [mount getMountImage:^(UIImage *image) {
        NSArray *nibViews =
            [[NSBundle mainBundle] loadNibNamed:@"HRPGImageOverlayView" owner:self options:nil];
        HRPGImageOverlayView *overlayView = nibViews[0];
        [overlayView displayImage:image];
        overlayView.imageWidth = 105;
        overlayView.imageHeight = 105;
        overlayView.titleText = NSLocalizedString(@"You raised a mount!", nil);
        overlayView.descriptionText = [NSString
            stringWithFormat:NSLocalizedString(
                                 @"By completing your tasks, you've earned a faithful steed!", nil),
                             (long)([self.user.level integerValue])];
        overlayView.dismissButtonText = NSLocalizedString(@"Huzzah!", nil);
        overlayView.shareAction = ^() {
            HRPGAppDelegate *del = (HRPGAppDelegate *)[UIApplication sharedApplication].delegate;
            UIViewController *activeViewController =
                del.window.rootViewController.presentedViewController;
            [HRPGSharingManager shareItems:@[
                [[NSString
                    stringWithFormat:NSLocalizedString(@"I just gained a %@ mount in Habitica by "
                                                       @"completing my real-life tasks!",
                                                       nil),
                                     mount.niceMountName]
                    stringByAppendingString:@" https://habitica.com/social/raise-mount"],
                image
            ]
                withPresentingViewController:activeViewController
             withSourceView:nil];
        };
        [overlayView sizeToFit];

        KLCPopup *popup = [KLCPopup popupWithContentView:overlayView
                                                showType:KLCPopupShowTypeBounceIn
                                             dismissType:KLCPopupDismissTypeBounceOut
                                                maskType:KLCPopupMaskTypeDimmed
                                dismissOnBackgroundTouch:YES
                                   dismissOnContentTouch:NO];
        [popup show];
    }];
}

- (void)displayNoGemAlert {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    UINavigationController *navigationController =
        [storyboard instantiateViewControllerWithIdentifier:@"PurchaseGemNavController"];
    UIViewController *viewController =
        [UIApplication sharedApplication].keyWindow.rootViewController;
    [viewController presentViewController:navigationController animated:YES completion:nil];
}

- (User *)getUser {
    return self.user;
}

- (void)getImage:(NSString *)imageName
      withFormat:(NSString *)format
       onSuccess:(void (^)(UIImage *image))successBlock
         onError:(void (^)())errorBlock {
    if (format == nil) {
        format = @"png";
    }

    YYWebImageManager *manager = [YYWebImageManager sharedManager];
    [manager
        requestImageWithURL:[NSURL
                                URLWithString:[NSString stringWithFormat:@"https://"
                                                                         @"habitica-assets.s3."
                                                                         @"amazonaws.com/"
                                                                         @"mobileApp/images/%@.%@",
                                                                         imageName, format]]
        options:0
        progress:nil
        transform:^UIImage *_Nullable(UIImage *_Nullable image, NSURL *_Nonnull url) {
            return [YYImage imageWithData:[image yy_imageDataRepresentation] scale:1.0];
        }
        completion:^(UIImage *_Nullable image, NSURL *_Nonnull url, YYWebImageFromType from,
                     YYWebImageStage stage, NSError *_Nullable error) {
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    successBlock(image);
                });
            } else {
                if (errorBlock) {
                    errorBlock();
                }
                NSLog(@"%@: %@", imageName, error);
            }

        }];
}

- (void)setImage:(NSString *)imageName
      withFormat:(NSString *)format
          onView:(UIImageView *)imageView {
    imageView.image = [UIImage imageNamed:@"Placeholder"];
    [self getImage:imageName
        withFormat:format
         onSuccess:^(UIImage *image) {
             imageView.image = image;
         }
           onError:nil];
}

- (UIImage *)getCachedImage:(NSString *)imageName {
    UIImage *image = [[YYImageCache sharedCache] getImageForKey:imageName];
    if (image) {
        return image;
    } else {
        return nil;
    }
}

- (void)setCachedImage:(UIImage *)image
              withName:(NSString *)imageName
             onSuccess:(void (^)())successBlock {
    [[YYImageCache sharedCache] setImage:image forKey:imageName];
    successBlock();
}

@end
