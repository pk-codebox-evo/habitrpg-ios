//
//  HRPGLoadingViewController.m
//  Habitica
//
//  Created by Phillip Thelen on 19/09/15.
//  Copyright (c) 2015 Phillip Thelen. All rights reserved.
//

#import "HRPGLoadingViewController.h"
#import <PDKeychainBindings.h>
#import "HRPGAppDelegate.h"
#import "HRPGAvatarSetupViewController.h"
#import "HRPGLoginViewController.h"

@interface HRPGLoadingViewController ()
@end

@implementation HRPGLoadingViewController

- (void)viewDidAppear:(BOOL)animated {
    PDKeychainBindings *keyChain = [PDKeychainBindings sharedKeychainBindings];
    if ([keyChain stringForKey:@"id"] == nil ||
        [[keyChain stringForKey:@"id"] isEqualToString:@""]) {
        [self performSegueWithIdentifier:@"LoginSegue" sender:self];
    } else {
        HRPGAppDelegate *appDelegate =
            (HRPGAppDelegate *)[[UIApplication sharedApplication] delegate];
        HRPGManager *manager = appDelegate.sharedManager;

        if ([manager getUser].username.length == 0) {
            self.activityIndicator.alpha = 1;
            [self.activityIndicator startAnimating];
            __weak HRPGLoadingViewController *weakSelf = self;
            [manager fetchUser:^() {
                [weakSelf performSegueWithIdentifier:@"InitialSegue" sender:self];
            }
                onError:^() {
                    [weakSelf performSegueWithIdentifier:@"InitialSegue" sender:self];
                }];
        } else {
            [self performSegueWithIdentifier:@"InitialSegue" sender:self];
        }
    }
    [super viewDidAppear:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    if (self.loadingFinishedAction) {
        self.loadingFinishedAction();
    }
    [super viewDidDisappear:YES];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"LoginSegue"]) {
        UINavigationController *navigationViewController = segue.destinationViewController;
        HRPGLoginViewController *loginViewController =
            (HRPGLoginViewController *)navigationViewController.topViewController;
        loginViewController.isRootViewController = YES;
    } else if ([segue.identifier isEqualToString:@"SetupSegue"]) {
        UINavigationController *navController = segue.destinationViewController;
        HRPGAvatarSetupViewController *avatarSetupViewController =
            (HRPGAvatarSetupViewController *)navController.topViewController;
        HRPGAppDelegate *appdelegate =
            (HRPGAppDelegate *)[[UIApplication sharedApplication] delegate];
        HRPGManager *manager = appdelegate.sharedManager;
        User *user = [manager getUser];
        avatarSetupViewController.user = user;
        avatarSetupViewController.managedObjectContext = manager.getManagedObjectContext;
    }
}

@end
