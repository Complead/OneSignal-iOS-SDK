/**
 * Modified MIT License
 *
 * Copyright 2017 OneSignal
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * 1. The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * 2. All copies of substantial portions of the Software may only be used in connection
 * with services provided by OneSignal.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#import "OneSignal.h"
#import "OneSignalInternal.h"
#import "OneSignalTracker.h"
#import "OneSignalTrackIAP.h"
#import "OneSignalLocation.h"
#import "OneSignalReachability.h"
#import "OneSignalJailbreakDetection.h"
#import "OneSignalMobileProvision.h"
#import "OneSignalAlertViewDelegate.h"
#import "OneSignalHelper.h"
#import "UNUserNotificationCenter+OneSignal.h"
#import "OneSignalSelectorHelpers.h"
#import "UIApplicationDelegate+OneSignal.h"
#import "NSString+OneSignal.h"
#import "OneSignalTrackFirebaseAnalytics.h"
#import "OneSignalNotificationServiceExtensionHandler.h"
#import "OSNotificationPayload+Internal.h"

#import "OneSignalNotificationSettings.h"
#import "OneSignalNotificationSettingsIOS10.h"
#import "OneSignalNotificationSettingsIOS8.h"
#import "OneSignalNotificationSettingsIOS7.h"

#import "OSObservable.h"

#import "OneSignalExtensionBadgeHandler.h"

#import <stdlib.h>
#import <stdio.h>
#import <sys/types.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#import "Requests.h"
#import "OneSignalClient.h"

#import <UserNotifications/UserNotifications.h>

#import "OneSignalSetEmailParameters.h"
#import "OneSignalCommonDefines.h"
#import "DelayedInitializationParameters.h"
#import "OneSignalDialogController.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static ONE_S_LOG_LEVEL _nsLogLevel = ONE_S_LL_WARN;
static ONE_S_LOG_LEVEL _visualLogLevel = ONE_S_LL_NONE;

NSString* const kOSSettingsKeyAutoPrompt = @"kOSSettingsKeyAutoPrompt";

/* Enable the default in-app alerts*/
NSString* const kOSSettingsKeyInAppAlerts = @"kOSSettingsKeyInAppAlerts";

/* Enable the default in-app launch urls*/
NSString* const kOSSettingsKeyInAppLaunchURL = @"kOSSettingsKeyInAppLaunchURL";

/* Set InFocusDisplayOption value must be an OSNotificationDisplayType enum*/
NSString* const kOSSettingsKeyInFocusDisplayOption = @"kOSSettingsKeyInFocusDisplayOption";

/* Omit no app_id error logging, for use with wrapper SDKs. */
NSString* const kOSSettingsKeyInOmitNoAppIdLogging = @"kOSSettingsKeyInOmitNoAppIdLogging";

/* Determine whether to automatically open push notification URL's or prompt user for permission */
NSString* const kOSSSettingsKeyPromptBeforeOpeningPushURL = @"kOSSSettingsKeyPromptBeforeOpeningPushURL";

/* Used to determine if the app is able to present it's own customized Notification Settings view (iOS 12+) */
NSString* const kOSSettingsKeyProvidesAppNotificationSettings = @"kOSSettingsKeyProvidesAppNotificationSettings";

@implementation OSPermissionSubscriptionState
- (NSString*)description {
    static NSString* format = @"<OSPermissionSubscriptionState:\npermissionStatus: %@,\nsubscriptionStatus: %@\n>";
    return [NSString stringWithFormat:format, _permissionStatus, _subscriptionStatus];
}
- (NSDictionary*)toDictionary {
    return @{@"permissionStatus": [_permissionStatus toDictionary],
             @"subscriptionStatus": [_subscriptionStatus toDictionary],
             @"emailSubscriptionStatus" : [_emailSubscriptionStatus toDictionary]
             };
}
@end

@interface OSPendingCallbacks : NSObject
 @property OSResultSuccessBlock successBlock;
 @property OSFailureBlock failureBlock;
@end

@implementation OSPendingCallbacks
@end

@implementation OneSignal

NSString* const ONESIGNAL_VERSION = @"021000";
static NSString* mSDKType = @"native";
static BOOL coldStartFromTapOnNotification = NO;

static BOOL shouldDelaySubscriptionUpdate = false;


/*
    if setEmail: was called before the device was registered (push playerID = nil),
    then the call to setEmail: also gets delayed
    this property stores the parameters so that once registration is complete
    we can finish setEmail:
*/
static OneSignalSetEmailParameters *delayedEmailParameters;

static NSMutableArray* pendingSendTagCallbacks;
static OSResultSuccessBlock pendingGetTagsSuccessBlock;
static OSFailureBlock pendingGetTagsFailureBlock;

// Has attempted to register for push notifications with Apple since app was installed.
static BOOL registeredWithApple = NO;

// UIApplication-registerForRemoteNotifications has been called but a success or failure has not triggered yet.
static BOOL waitingForApnsResponse = false;

// Under Capabilities is "Background Modes" > "Remote notifications" enabled.
static BOOL backgroundModesEnabled = false;

// indicates if the GetiOSParams request has completed
static BOOL downloadedParameters = false;
static BOOL didCallDownloadParameters = false;

static BOOL promptBeforeOpeningPushURLs = false;


// Indicates if initialization of the SDK has been delayed until the user gives privacy consent
static BOOL delayedInitializationForPrivacyConsent = false;

// If initialization is delayed, this object holds params such as the app ID so that the init()
// method can be called the moment the user provides privacy consent.
DelayedInitializationParameters *delayedInitParameters;

//used to ensure registration occurs even if APNS does not respond
static NSDate *initializationTime;
static NSTimeInterval maxApnsWait = APNS_TIMEOUT;
static NSTimeInterval reattemptRegistrationInterval = REGISTRATION_DELAY_SECONDS;

//the iOS Native SDK will use the plist flag to enable privacy consent
//however wrapper SDK's will use a method call before initialization
//this boolean flag is switched on to enable this behavior
static BOOL shouldRequireUserConsent = false;

static OneSignalTrackIAP* trackIAPPurchase;
static NSString* app_id;
NSString* emailToSet;
NSMutableDictionary* tagsToSend;
OSResultSuccessBlock tokenUpdateSuccessBlock;
OSFailureBlock tokenUpdateFailureBlock;

int mLastNotificationTypes = -1;
static int mSubscriptionStatus = -1;

OSIdsAvailableBlock idsAvailableBlockWhenReady;
BOOL disableBadgeClearing = NO;
BOOL mShareLocation = YES;
BOOL requestedProvisionalAuthorization = false;
BOOL usesAutoPrompt = false;

static BOOL providesAppNotificationSettings = false;

static BOOL performedOnSessionRequest = false;
static NSString *pendingExternalUserId;

// Notification Display Type Delegate
static __weak id<OSNotificationDisplayTypeDelegate> _displayDelegate;

// Display type is used in multiple areas of the SDK
// To avoid calling the delegate multiple times, we store
// the type and notification ID for each notification
// These data structures *MUST* be accessed on the main thread only
static NSMutableDictionary<NSString *, NSNumber *> *_displayTypeMap;
static NSMutableDictionary<NSString *, NSMutableArray<OSNotificationDisplayTypeResponse> *> *_pendingDisplayTypeCallbacks;

static OSNotificationDisplayType _inFocusDisplayType = OSNotificationDisplayTypeInAppAlert;
+ (void)setInFocusDisplayType:(OSNotificationDisplayType)value {
    NSInteger op = value;
    if (![OneSignalHelper isIOSVersionGreaterOrEqual:10] && OSNotificationDisplayTypeNotification == op)
        op = OSNotificationDisplayTypeInAppAlert;
    
    _inFocusDisplayType = op;
}
+ (OSNotificationDisplayType)inFocusDisplayType {
    return _inFocusDisplayType;
}

// iOS version implemation
static NSObject<OneSignalNotificationSettings>* _osNotificationSettings;
+ (NSObject<OneSignalNotificationSettings>*)osNotificationSettings {
    if (!_osNotificationSettings) {
        if ([OneSignalHelper isIOSVersionGreaterOrEqual:10])
            _osNotificationSettings = [OneSignalNotificationSettingsIOS10 new];
        else if ([OneSignalHelper isIOSVersionGreaterOrEqual:8])
            _osNotificationSettings = [OneSignalNotificationSettingsIOS8 new];
        else
            _osNotificationSettings = [OneSignalNotificationSettingsIOS7 new];
    }
    return _osNotificationSettings;
}


// static property def for currentPermissionState
static OSPermissionState* _currentPermissionState;
+ (OSPermissionState*)currentPermissionState {
    if (!_currentPermissionState) {
        _currentPermissionState = [OSPermissionState alloc];
        _currentPermissionState = [_currentPermissionState initAsTo];
        [self lastPermissionState]; // Trigger creation
        [_currentPermissionState.observable addObserver:[OSPermissionChangedInternalObserver alloc]];
    }
    return _currentPermissionState;
}

// static property def for previous OSSubscriptionState
static OSPermissionState* _lastPermissionState;
+ (OSPermissionState*)lastPermissionState {
    if (!_lastPermissionState)
        _lastPermissionState = [[OSPermissionState alloc] initAsFrom];
    return _lastPermissionState;
}
+ (void)setLastPermissionState:(OSPermissionState *)lastPermissionState {
    _lastPermissionState = lastPermissionState;
}

static OSEmailSubscriptionState* _currentEmailSubscriptionState;
+ (OSEmailSubscriptionState *)currentEmailSubscriptionState {
    if (!_currentEmailSubscriptionState) {
        _currentEmailSubscriptionState = [[OSEmailSubscriptionState alloc] init];
        
        [_currentEmailSubscriptionState.observable addObserver:[OSEmailSubscriptionChangedInternalObserver alloc]];
    }
    return _currentEmailSubscriptionState;
}

static OSEmailSubscriptionState *_lastEmailSubscriptionState;
+ (OSEmailSubscriptionState *)lastEmailSubscriptionState {
    if (!_lastEmailSubscriptionState) {
        _lastEmailSubscriptionState = [[OSEmailSubscriptionState alloc] init];
    }
    return _lastEmailSubscriptionState;
}

+ (void)setLastEmailSubscriptionState:(OSEmailSubscriptionState *)lastEmailSubscriptionState {
    _lastEmailSubscriptionState = lastEmailSubscriptionState;
}

// static property def for current OSSubscriptionState
static OSSubscriptionState* _currentSubscriptionState;
+ (OSSubscriptionState*)currentSubscriptionState {
    if (!_currentSubscriptionState) {
        _currentSubscriptionState = [OSSubscriptionState alloc];
        _currentSubscriptionState = [_currentSubscriptionState initAsToWithPermision:self.currentPermissionState.accepted];
        mLastNotificationTypes = _currentPermissionState.notificationTypes;
        [self.currentPermissionState.observable addObserver:_currentSubscriptionState];
        [_currentSubscriptionState.observable addObserver:[OSSubscriptionChangedInternalObserver alloc]];
    }
    return _currentSubscriptionState;
}

static OSSubscriptionState* _lastSubscriptionState;
+ (OSSubscriptionState*)lastSubscriptionState {
    if (!_lastSubscriptionState) {
        _lastSubscriptionState = [OSSubscriptionState alloc];
        _lastSubscriptionState = [_lastSubscriptionState initAsFrom];
    }
    return _lastSubscriptionState;
}
+ (void)setLastSubscriptionState:(OSSubscriptionState*)lastSubscriptionState {
    _lastSubscriptionState = lastSubscriptionState;
}


// static property def to add developer's OSPermissionStateChanges observers to.
static ObserablePermissionStateChangesType* _permissionStateChangesObserver;
+ (ObserablePermissionStateChangesType*)permissionStateChangesObserver {
    if (!_permissionStateChangesObserver)
        _permissionStateChangesObserver = [[OSObservable alloc] initWithChangeSelector:@selector(onOSPermissionChanged:)];
    return _permissionStateChangesObserver;
}

static ObservableSubscriptionStateChangesType* _subscriptionStateChangesObserver;
+ (ObservableSubscriptionStateChangesType*)subscriptionStateChangesObserver {
    if (!_subscriptionStateChangesObserver)
        _subscriptionStateChangesObserver = [[OSObservable alloc] initWithChangeSelector:@selector(onOSSubscriptionChanged:)];
    return _subscriptionStateChangesObserver;
}

static ObservableEmailSubscriptionStateChangesType* _emailSubscriptionStateChangesObserver;
+ (ObservableEmailSubscriptionStateChangesType *)emailSubscriptionStateChangesObserver {
    if (!_emailSubscriptionStateChangesObserver)
        _emailSubscriptionStateChangesObserver = [[OSObservable alloc] initWithChangeSelector:@selector(onOSEmailSubscriptionChanged:)];
    return _emailSubscriptionStateChangesObserver;
}

+ (void)setMSubscriptionStatus:(NSNumber*)status {
    mSubscriptionStatus = [status intValue];
}
    
+ (NSString*)app_id {
    return app_id;
}

+ (NSString*)sdk_version_raw {
	return ONESIGNAL_VERSION;
}

+ (NSString*)sdk_semantic_version {
	// examples:
	// ONESIGNAL_VERSION = @"020402" returns 2.4.2
	// ONESIGNAL_VERSION = @"001000" returns 0.10.0
	// so that's 6 digits, where the first two are the major version
	// the second two are the minor version and that last two, the patch.
	// c.f. http://semver.org/

	return [ONESIGNAL_VERSION one_getSemanticVersion];
}

+ (NSString*)mUserId {
    return self.currentSubscriptionState.userId;
}

+ (NSString *)mEmailAuthToken {
    return self.currentEmailSubscriptionState.emailAuthCode;
}

+ (NSString *)mEmailUserId {
    return self.currentEmailSubscriptionState.emailUserId;
}

+ (void)setMSDKType:(NSString*)type {
    mSDKType = type;
}

+ (void) setWaitingForApnsResponse:(BOOL)value {
    waitingForApnsResponse = value;
}

// Used for testing purposes to decrease the amount of time the
// SDK will spend waiting for a response from APNS before it
// gives up and registers with OneSignal anyways
+ (void)setDelayIntervals:(NSTimeInterval)apnsMaxWait withRegistrationDelay:(NSTimeInterval)registrationDelay {
    reattemptRegistrationInterval = registrationDelay;
    maxApnsWait = apnsMaxWait;
}

+ (void)clearStatics {
    usesAutoPrompt = false;
    requestedProvisionalAuthorization = false;
    
    app_id = nil;
    _osNotificationSettings = nil;
    waitingForApnsResponse = false;
    mLastNotificationTypes = -1;
    
    _lastPermissionState = nil;
    _currentPermissionState = nil;
    
    _currentEmailSubscriptionState = nil;
    _lastEmailSubscriptionState = nil;
    _lastSubscriptionState = nil;
    _currentSubscriptionState = nil;
    
    _permissionStateChangesObserver = nil;
    
    didCallDownloadParameters = false;
    
    maxApnsWait = APNS_TIMEOUT;
    reattemptRegistrationInterval = REGISTRATION_DELAY_SECONDS;
    
    performedOnSessionRequest = false;
    pendingExternalUserId = nil;
    
    _displayDelegate = nil;
    _displayTypeMap = [NSMutableDictionary new];
    _pendingDisplayTypeCallbacks = [NSMutableDictionary new];
}

// Set to false as soon as it's read.
+ (BOOL)coldStartFromTapOnNotification {
    BOOL val = coldStartFromTapOnNotification;
    coldStartFromTapOnNotification = NO;
    return val;
}

+ (BOOL)shouldDelaySubscriptionSettingsUpdate {
    return shouldDelaySubscriptionUpdate;
}
    
+ (id)initWithLaunchOptions:(NSDictionary*)launchOptions appId:(NSString*)appId {
    return [self initWithLaunchOptions: launchOptions appId: appId handleNotificationReceived: NULL handleNotificationAction : NULL settings: @{kOSSettingsKeyAutoPrompt : @YES, kOSSettingsKeyInAppAlerts : @YES, kOSSettingsKeyInAppLaunchURL : @YES, kOSSSettingsKeyPromptBeforeOpeningPushURL : @NO}];
}

+ (id)initWithLaunchOptions:(NSDictionary*)launchOptions appId:(NSString*)appId handleNotificationAction:(OSHandleNotificationActionBlock)actionCallback {
    return [self initWithLaunchOptions: launchOptions appId: appId handleNotificationReceived: NULL handleNotificationAction : actionCallback settings: @{kOSSettingsKeyAutoPrompt : @YES, kOSSettingsKeyInAppAlerts : @YES, kOSSettingsKeyInAppLaunchURL : @YES, kOSSSettingsKeyPromptBeforeOpeningPushURL : @NO}];
}

+ (id)initWithLaunchOptions:(NSDictionary*)launchOptions appId:(NSString*)appId handleNotificationAction:(OSHandleNotificationActionBlock)actionCallback settings:(NSDictionary*)settings {
    return [self initWithLaunchOptions: launchOptions appId: appId handleNotificationReceived: NULL handleNotificationAction : actionCallback settings: settings];
}

// NOTE: Wrapper SDKs such as Unity3D will call this method with appId set to nil so open events are not lost.
//         Ensure a 2nd call can be made later with the appId from the developer's code.
+ (id)initWithLaunchOptions:(NSDictionary*)launchOptions appId:(NSString*)appId handleNotificationReceived:(OSHandleNotificationReceivedBlock)receivedCallback handleNotificationAction:(OSHandleNotificationActionBlock)actionCallback settings:(NSDictionary*)settings {
    [self onesignal_Log:ONE_S_LL_VERBOSE message:[NSString stringWithFormat:@"Called init with app ID: %@", appId]];
    
    initializationTime = [NSDate date];
    
    //Some wrapper SDK's call init multiple times and pass nil/NSNull as the appId on the first call
    //the app ID is required to download parameters, so do not download params until the appID is provided
    if (!didCallDownloadParameters && appId != nil && appId != (id)[NSNull null])
        [self downloadIOSParamsWithAppId:appId];
    
    if ([self requiresUserPrivacyConsent]) {
        delayedInitializationForPrivacyConsent = true;
        delayedInitParameters = [[DelayedInitializationParameters alloc] initWithLaunchOptions:launchOptions withAppId:appId withHandleNotificationReceivedBlock:receivedCallback withHandleNotificationActionBlock:actionCallback withSettings:settings];
        [self onesignal_Log:ONE_S_LL_VERBOSE message:@"Delayed initialization of the OneSignal SDK until the user provides privacy consent using the consentGranted() method"];
        return self;
    }
    
    let userDefaults = [NSUserDefaults standardUserDefaults];
    
    let success = [self initAppId:appId
                 withUserDefaults:userDefaults
                        withSettings:settings];
    
    if (!success)
        return self;
    
    if (appId && mShareLocation)
       [OneSignalLocation getLocation:false];
    
    if (self) {
        [OneSignal checkIfApplicationImplementsDeprecatedMethods];
        
        [OneSignalHelper notificationBlocks: receivedCallback : actionCallback];
        
        if ([OneSignalHelper isIOSVersionGreaterOrEqual:8])
            registeredWithApple = self.currentPermissionState.accepted;
        else
            registeredWithApple = self.currentSubscriptionState.pushToken || [userDefaults boolForKey:@"GT_REGISTERED_WITH_APPLE"];
        
        // Check if disabled in-app launch url if passed a NO
        if (settings[kOSSettingsKeyInAppLaunchURL] && [settings[kOSSettingsKeyInAppLaunchURL] isKindOfClass:[NSNumber class]]) {
            [self enableInAppLaunchURL:settings[kOSSettingsKeyInAppLaunchURL]];
        } else if (![[NSUserDefaults standardUserDefaults] objectForKey:@"ONESIGNAL_INAPP_LAUNCH_URL"]) {
            //only need to default to @YES if the app doesn't already have this setting saved in NSUserDefaults
            [self enableInAppLaunchURL:@YES];
        }
        
        if (settings[kOSSSettingsKeyPromptBeforeOpeningPushURL] && [settings[kOSSSettingsKeyPromptBeforeOpeningPushURL] isKindOfClass:[NSNumber class]]) {
            promptBeforeOpeningPushURLs = [settings[kOSSSettingsKeyPromptBeforeOpeningPushURL] boolValue];
            [userDefaults setObject:settings[kOSSSettingsKeyPromptBeforeOpeningPushURL] forKey:PROMPT_BEFORE_OPENING_PUSH_URL];
            [userDefaults synchronize];
        } else if ([userDefaults objectForKey:PROMPT_BEFORE_OPENING_PUSH_URL]) {
            promptBeforeOpeningPushURLs = [[userDefaults objectForKey:PROMPT_BEFORE_OPENING_PUSH_URL] boolValue];
        }
        
        usesAutoPrompt = YES;
        if (settings[kOSSettingsKeyAutoPrompt] && [settings[kOSSettingsKeyAutoPrompt] isKindOfClass:[NSNumber class]])
            usesAutoPrompt = [settings[kOSSettingsKeyAutoPrompt] boolValue];
        
        if (settings[kOSSettingsKeyProvidesAppNotificationSettings] && [settings[kOSSettingsKeyProvidesAppNotificationSettings] isKindOfClass:[NSNumber class]] && [OneSignalHelper isIOSVersionGreaterOrEqual:12.0])
            providesAppNotificationSettings = [settings[kOSSettingsKeyProvidesAppNotificationSettings] boolValue];
        
        // Register with Apple's APNS server if we registed once before or if auto-prompt hasn't been disabled.
        if (usesAutoPrompt || registeredWithApple) {
            [self registerForPushNotifications];
        } else {
            [self checkProvisionalAuthorizationStatus];
            [self registerForAPNsToken];
        }
        
        
        /* Check if in-app setting passed assigned
            LOGIC: Default - InAppAlerts enabled / InFocusDisplayOption InAppAlert.
            Priority for kOSSettingsKeyInFocusDisplayOption.
        */
        NSNumber *IAASetting = settings[kOSSettingsKeyInAppAlerts];
        let inAppAlertsPassed = IAASetting && (IAASetting.integerValue == 0 || IAASetting.integerValue == 1);
        
        NSNumber *IFDSetting = settings[kOSSettingsKeyInFocusDisplayOption];
        let inFocusDisplayPassed = IFDSetting && IFDSetting.integerValue > -1 && IFDSetting.integerValue < 3;
        
        if (inAppAlertsPassed || inFocusDisplayPassed) {
            if (!inFocusDisplayPassed)
                self.inFocusDisplayType = (OSNotificationDisplayType)IAASetting.integerValue;
            else
                self.inFocusDisplayType = (OSNotificationDisplayType)IFDSetting.integerValue;
        }

        
        if (self.currentSubscriptionState.userId)
            [self registerUser];
        else {
            [self.osNotificationSettings getNotificationPermissionState:^(OSPermissionState *state) {
                
                if (state.answeredPrompt) {
                    [self registerUser];
                } else {
                    [self registerUserAfterDelay];
                }
            }];
        }
    }
 
    /*
     * No need to call the handleNotificationOpened:userInfo as it will be called from one of the following selectors
     *  - application:didReceiveRemoteNotification:fetchCompletionHandler
     *  - userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler (iOS10)
     */
    
    // Cold start from tap on a remote notification
    //  NOTE: launchOptions may be nil if tapping on a notification's action button.
    NSDictionary* userInfo = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
    if (userInfo)
        coldStartFromTapOnNotification = YES;

    [self clearBadgeCount:false];
    
    if (!trackIAPPurchase && [OneSignalTrackIAP canTrack])
        trackIAPPurchase = [[OneSignalTrackIAP alloc] init];
    
    if (NSClassFromString(@"UNUserNotificationCenter"))
       [OneSignalHelper clearCachedMedia];
    
    /*
     downloads params file to see:
         (A) if firebase analytics should be tracked
         (B) if this app requires email authentication
    */
    
    if ([OneSignalTrackFirebaseAnalytics needsRemoteParams]) {
        [OneSignalTrackFirebaseAnalytics init];
    }
    
    return self;
}

+(bool)initAppId:(NSString*)appId withUserDefaults:(NSUserDefaults*)userDefaults withSettings:(NSDictionary*)settings {
    if (appId)
        app_id = appId;
    else {
        // Read from .plist if not passed in with this method call.
        app_id = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"OneSignal_APPID"];
        if (app_id == nil)
            app_id = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"GameThrive_APPID"];
    }
    
    if (!app_id) {
        app_id  = [userDefaults stringForKey:@"GT_APP_ID"];
        if (![settings[kOSSettingsKeyInOmitNoAppIdLogging] boolValue])
            onesignal_Log(ONE_S_LL_FATAL, @"OneSignal AppId never set!");
        else
            return true;
    }
    else if (![app_id isEqualToString:[userDefaults stringForKey:@"GT_APP_ID"]]) {
        // Handle changes to the app id. This might happen on a developer's device when testing
        // Will also run the first time OneSignal is initialized
        [userDefaults setObject:app_id forKey:@"GT_APP_ID"];
        [userDefaults setObject:nil forKey:USERID];
        [userDefaults synchronize];
    }
    
    if (!app_id || ![[NSUUID alloc] initWithUUIDString:app_id]) {
        onesignal_Log(ONE_S_LL_FATAL, @"OneSignal AppId format is invalid.\nExample: 'b2f7f966-d8cc-11e4-bed1-df8f05be55ba'\n");
        return false;
    }
    
    if ([@"b2f7f966-d8cc-11e4-bed1-df8f05be55ba" isEqualToString:appId] || [@"5eb5a37e-b458-11e3-ac11-000c2940e62c" isEqualToString:appId])
        onesignal_Log(ONE_S_LL_WARN, @"OneSignal Example AppID detected, please update to your app's id found on OneSignal.com");
    
    return true;
}

// Checks to see if we should register for APNS' new Provisional authorization
// (also known as Direct to History).
// This behavior is determined by the OneSignal Parameters request
+ (void)checkProvisionalAuthorizationStatus {
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    let usesProvisional = (NSNumber *)[[NSUserDefaults standardUserDefaults] objectForKey:USES_PROVISIONAL_AUTHORIZATION];
    
    // if iOS parameters for this app have never downloaded, this method
    // should return
    if (!usesProvisional || ![usesProvisional boolValue] || requestedProvisionalAuthorization)
        return;
    
    requestedProvisionalAuthorization = true;
    
    [self.osNotificationSettings registerForProvisionalAuthorization:nil];
}

+ (void)registerForProvisionalAuthorization:(void(^)(BOOL accepted))completionHandler {
    if ([OneSignalHelper isIOSVersionGreaterOrEqual:12.0])
        [self.osNotificationSettings registerForProvisionalAuthorization:completionHandler];
    else
        onesignal_Log(ONE_S_LL_WARN, @"registerForProvisionalAuthorization is only available in iOS 12+.");
}

+ (BOOL)shouldLogMissingPrivacyConsentErrorWithMethodName:(NSString *)methodName {
    if ([self requiresUserPrivacyConsent]) {
        if (methodName) {
            [self onesignal_Log:ONE_S_LL_WARN message:[NSString stringWithFormat:@"Your application has called %@ before the user granted privacy permission. Please call `consentGranted(bool)` in order to provide user privacy consent", methodName]];
        }
        return true;
    }
    
    return false;
}

+ (void)setRequiresUserPrivacyConsent:(BOOL)required {
    shouldRequireUserConsent = required;
}

+ (BOOL)requiresUserPrivacyConsent {
    
    // if the plist key does not exist default to true
    // the plist value specifies whether GDPR privacy consent is required for this app
    // if required and consent has not been previously granted, return false
    
    let requiresConsent = [[[NSBundle mainBundle] objectForInfoDictionaryKey:ONESIGNAL_REQUIRE_PRIVACY_CONSENT] boolValue] ?: false;
    
    if (requiresConsent || shouldRequireUserConsent) {
        let userDefaults = [NSUserDefaults standardUserDefaults];
        
        let consentGranted = (NSNumber *)[userDefaults objectForKey:GDPR_CONSENT_GRANTED];
        
        if (consentGranted == nil) {
            [userDefaults setObject:@false forKey:GDPR_CONSENT_GRANTED];
            [userDefaults synchronize];
        }
        
        return ![[userDefaults objectForKey:GDPR_CONSENT_GRANTED] boolValue];
    }
    
    return false;
}

+ (void)consentGranted:(BOOL)granted {
    let userDefaults = [NSUserDefaults standardUserDefaults];
    
    [userDefaults setObject:@(granted) forKey:GDPR_CONSENT_GRANTED];
    [userDefaults synchronize];
    
    if (!granted || !delayedInitializationForPrivacyConsent || delayedInitParameters == nil)
        return;
    
    [self initWithLaunchOptions:delayedInitParameters.launchOptions appId:delayedInitParameters.appId handleNotificationReceived:delayedInitParameters.receivedBlock handleNotificationAction:delayedInitParameters.actionBlock settings:delayedInitParameters.settings];
    delayedInitializationForPrivacyConsent = false;
    delayedInitParameters = nil;
}

// the iOS SDK used to call these selectors as a convenience but has stopped due to concerns about private API usage
// the SDK will now print warnings when a developer's app implements these selectors
+ (void)checkIfApplicationImplementsDeprecatedMethods {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *selectorName in DEPRECATED_SELECTORS)
            if ([[[UIApplication sharedApplication] delegate] respondsToSelector:NSSelectorFromString(selectorName)])
                [OneSignal onesignal_Log:ONE_S_LL_WARN message:[NSString stringWithFormat:@"OneSignal has detected that your application delegate implements a deprecated method (%@). Please note that this method has been officially deprecated and the OneSignal SDK will no longer call it. You should use UNUserNotificationCenter instead", selectorName]];
    });
}

+(void)downloadIOSParamsWithAppId:(NSString *)appId {
    [self onesignal_Log:ONE_S_LL_DEBUG message:@"Downloading iOS parameters for this application"];
    didCallDownloadParameters = true;
    
    [OneSignalClient.sharedClient executeRequest:[OSRequestGetIosParams withUserId:self.currentSubscriptionState.userId appId:appId] onSuccess:^(NSDictionary *result) {
        if (result[IOS_REQUIRES_EMAIL_AUTHENTICATION]) {
            self.currentEmailSubscriptionState.requiresEmailAuth = [result[IOS_REQUIRES_EMAIL_AUTHENTICATION] boolValue];
            
            // checks if a cell to setEmail: was delayed due to missing 'requiresEmailAuth' parameter
            if (delayedEmailParameters && self.currentSubscriptionState.userId) {
                [self setEmail:delayedEmailParameters.email withEmailAuthHashToken:delayedEmailParameters.authToken withSuccess:delayedEmailParameters.successBlock withFailure:delayedEmailParameters.failureBlock];
                delayedEmailParameters = nil;
            }
        }
        if (!usesAutoPrompt && result[IOS_USES_PROVISIONAL_AUTHORIZATION] && result[IOS_USES_PROVISIONAL_AUTHORIZATION] != [NSNull null] && [result[IOS_USES_PROVISIONAL_AUTHORIZATION] boolValue]) {
            let defaults = [NSUserDefaults standardUserDefaults];
            
            [defaults setObject:@true forKey:USES_PROVISIONAL_AUTHORIZATION];
            [defaults synchronize];
            
            [self checkProvisionalAuthorizationStatus];
        }
        
        [OneSignalTrackFirebaseAnalytics updateFromDownloadParams:result];
        
        downloadedParameters = true;
    } onFailure:nil];
}

+ (void)setLogLevel:(ONE_S_LOG_LEVEL)nsLogLevel visualLevel:(ONE_S_LOG_LEVEL)visualLogLevel {
    _nsLogLevel = nsLogLevel; _visualLogLevel = visualLogLevel;
}

+ (void) onesignal_Log:(ONE_S_LOG_LEVEL)logLevel message:(NSString*) message {
    onesignal_Log(logLevel, message);
}

void onesignal_Log(ONE_S_LOG_LEVEL logLevel, NSString* message) {
    NSString* levelString;
    switch (logLevel) {
        case ONE_S_LL_FATAL:
            levelString = @"FATAL: ";
            break;
        case ONE_S_LL_ERROR:
            levelString = @"ERROR: ";
            break;
        case ONE_S_LL_WARN:
            levelString = @"WARNING: ";
            break;
        case ONE_S_LL_INFO:
            levelString = @"INFO: ";
            break;
        case ONE_S_LL_DEBUG:
            levelString = @"DEBUG: ";
            break;
        case ONE_S_LL_VERBOSE:
            levelString = @"VERBOSE: ";
            break;
            
        default:
            break;
    }

    if (logLevel <= _nsLogLevel)
        NSLog(@"%@", [levelString stringByAppendingString:message]);
    
    if (logLevel <= _visualLogLevel) {
        [[OneSignalDialogController sharedInstance] presentDialogWithTitle:levelString withMessage:message withAction:nil cancelTitle:NSLocalizedString(@"Close", @"Close button") withActionCompletion:nil];
    }
}

//presents the settings page to control/customize push notification settings
+ (void)presentAppSettings {
    
    //only supported in 10+
    if (![OneSignalHelper isIOSVersionGreaterOrEqual:10.0])
        return;
    
    let url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    
    if (!url)
        return;
    
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        [self onesignal_Log:ONE_S_LL_ERROR message:@"Unable to open settings for this application"];
    }
}

// iOS 12+ only
// A boolean indicating if the app provides its own custom Notifications Settings UI
// If this is set to TRUE via the kOSSettingsKeyProvidesAppNotificationSettings init
// parameter, the SDK will request authorization from the User Notification Center
+ (BOOL)providesAppNotificationSettings {
    return providesAppNotificationSettings;
}

// iOS 8+, only tries to register for an APNs token
+ (BOOL)registerForAPNsToken {
    if (![OneSignalHelper isIOSVersionGreaterOrEqual:8])
        return false;
    
    if (waitingForApnsResponse)
        return true;
    
    id backgroundModes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
    backgroundModesEnabled = (backgroundModes && [backgroundModes containsObject:@"remote-notification"]);
    
    // Only try to register for a pushToken if:
    //  - The user accepted notifications
    //  - "Background Modes" > "Remote Notifications" are enabled in Xcode
    if (![self.osNotificationSettings getNotificationPermissionState].accepted && !backgroundModesEnabled)
        return false;
    
    // Don't attempt to register again if there was a non-recoverable error.
    if (mSubscriptionStatus < -9)
        return false;
    
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:@"Firing registerForRemoteNotifications"];
    
    waitingForApnsResponse = true;
    [[UIApplication sharedApplication] registerForRemoteNotifications];
    
    return true;
}

// if user has disabled push notifications & fallback == true,
// the SDK will prompt the user to open notification Settings for this app
+ (void)promptForPushNotificationsWithUserResponse:(void (^)(BOOL accepted))completionHandler fallbackToSettings:(BOOL)fallback {
    
    if (self.currentPermissionState.hasPrompted == true && self.osNotificationSettings.getNotificationTypes == 0 && fallback) {
        //show settings
        
        if (completionHandler)
            completionHandler(false);
        
        let localizedTitle = NSLocalizedString(@"Open Settings", @"A title saying that the user can open iOS Settings");
        let localizedSettingsActionTitle = NSLocalizedString(@"Open Settings", @"A button allowing the user to open the Settings app");
        let localizedCancelActionTitle = NSLocalizedString(@"Cancel", @"A button allowing the user to close the Settings prompt");
        
        //the developer can provide a custom message in Info.plist if they choose.
        var localizedMessage = (NSString *)[[NSBundle mainBundle] objectForInfoDictionaryKey:FALLBACK_TO_SETTINGS_MESSAGE];
        
        if (!localizedMessage)
            localizedMessage = NSLocalizedString(@"You currently have notifications turned off for this application. You can open Settings to re-enable them", @"A message explaining that users can open Settings to re-enable push notifications");
        
        
        [[OneSignalDialogController sharedInstance] presentDialogWithTitle:localizedTitle withMessage:localizedMessage withAction:localizedSettingsActionTitle cancelTitle:localizedCancelActionTitle withActionCompletion:^(BOOL tappedAction) {
            
            //completion is called on the main thread
            if (tappedAction)
                [self presentAppSettings];
        }];
        
        return;
    }
    
    [self promptForPushNotificationsWithUserResponse:completionHandler];
}

+ (void)promptForPushNotificationsWithUserResponse:(void(^)(BOOL accepted))completionHandler {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"promptForPushNotificationsWithUserResponse:"])
        return;
    
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:[NSString stringWithFormat:@"registerForPushNotifications Called:waitingForApnsResponse: %d", waitingForApnsResponse]];
    
    self.currentPermissionState.hasPrompted = true;
    
    [self.osNotificationSettings promptForNotifications:completionHandler];
}

// This registers for a push token and prompts the user for notifiations permisions
//    Will trigger didRegisterForRemoteNotificationsWithDeviceToken on the AppDelegate when APNs responses.
+ (void)registerForPushNotifications {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"registerForPushNotifications:"])
        return;
    
    [self promptForPushNotificationsWithUserResponse:nil];
}


+ (OSPermissionSubscriptionState*)getPermissionSubscriptionState {
    OSPermissionSubscriptionState* status = [OSPermissionSubscriptionState alloc];
    
    status.subscriptionStatus = self.currentSubscriptionState;
    status.permissionStatus = self.currentPermissionState;
    status.emailSubscriptionStatus = self.currentEmailSubscriptionState;
    
    return status;
}

+ (void)setNotificationDisplayTypeDelegate:(NSObject<OSNotificationDisplayTypeDelegate> *)delegate {
    _displayDelegate = delegate;
}

// onOSPermissionChanged should only fire if something changed.
+ (void)addPermissionObserver:(NSObject<OSPermissionObserver>*)observer {
    [self.permissionStateChangesObserver addObserver:observer];
    
    if ([self.currentPermissionState compare:self.lastPermissionState])
        [OSPermissionChangedInternalObserver fireChangesObserver:self.currentPermissionState];
}
+ (void)removePermissionObserver:(NSObject<OSPermissionObserver>*)observer {
    [self.permissionStateChangesObserver removeObserver:observer];
}


// onOSSubscriptionChanged should only fire if something changed.
+ (void)addSubscriptionObserver:(NSObject<OSSubscriptionObserver>*)observer {
    [self.subscriptionStateChangesObserver addObserver:observer];
    
    if ([self.currentSubscriptionState compare:self.lastSubscriptionState])
        [OSSubscriptionChangedInternalObserver fireChangesObserver:self.currentSubscriptionState];
}

+ (void)removeSubscriptionObserver:(NSObject<OSSubscriptionObserver>*)observer {
    [self.subscriptionStateChangesObserver removeObserver:observer];
}

+ (void)addEmailSubscriptionObserver:(NSObject<OSEmailSubscriptionObserver>*)observer {
    [self.emailSubscriptionStateChangesObserver addObserver:observer];
    
    if ([self.currentEmailSubscriptionState compare:self.lastEmailSubscriptionState])
        [OSEmailSubscriptionChangedInternalObserver fireChangesObserver:self.currentEmailSubscriptionState];
}

+ (void)removeEmailSubscriptionObserver:(NSObject<OSEmailSubscriptionObserver>*)observer {
    [self.emailSubscriptionStateChangesObserver removeObserver:observer];
}

// Block not assigned if userID nil and there is a device token
+ (void)IdsAvailable:(OSIdsAvailableBlock)idsAvailableBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"IdsAvailable:"])
        return;
    
    idsAvailableBlockWhenReady = idsAvailableBlock;
    [self fireIdsAvailableCallback];
}

+ (void) fireIdsAvailableCallback {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    if (!idsAvailableBlockWhenReady)
        return;
    if (!self.currentSubscriptionState.userId)
        return;
    
    // Ensure we are on the main thread incase app developer updates UI from the callback.
    [OneSignalHelper dispatch_async_on_main_queue: ^{
        id pushToken = [self getUsableDeviceToken];
        if (!idsAvailableBlockWhenReady)
            return;
        idsAvailableBlockWhenReady(self.currentSubscriptionState.userId, pushToken);
        if (pushToken)
           idsAvailableBlockWhenReady = nil;
    }];
}

+ (void)sendTagsWithJsonString:(NSString*)jsonString {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"sendTagsWithJsonString:"])
        return;
    
    NSError* jsonError;
    
    NSData* data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* keyValuePairs = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
    if (jsonError == nil) {
        [self sendTags:keyValuePairs];
    } else {
        onesignal_Log(ONE_S_LL_WARN,[NSString stringWithFormat: @"sendTags JSON Parse Error: %@", jsonError]);
        onesignal_Log(ONE_S_LL_WARN,[NSString stringWithFormat: @"sendTags JSON Parse Error, JSON: %@", jsonString]);
    }
}

+ (void)sendTags:(NSDictionary*)keyValuePair {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"sendTags:"])
        return;
    
    [self sendTags:keyValuePair onSuccess:nil onFailure:nil];
}

+ (void)sendTags:(NSDictionary*)keyValuePair onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"sendTags:onSuccess:onFailure:"])
        return;
   
    if (![NSJSONSerialization isValidJSONObject:keyValuePair]) {
        onesignal_Log(ONE_S_LL_WARN, [NSString stringWithFormat:@"sendTags JSON Invalid: The following key/value pairs you attempted to send as tags are not valid JSON: %@", keyValuePair]);
        return;
    }
    
    for (NSString *key in [keyValuePair allKeys]) {
        if ([keyValuePair[key] isKindOfClass:[NSDictionary class]]) {
            onesignal_Log(ONE_S_LL_WARN, @"sendTags Tags JSON must not contain nested objects");
            return;
        }
    }
    
    if (tagsToSend == nil)
        tagsToSend = [keyValuePair mutableCopy];
    else
        [tagsToSend addEntriesFromDictionary:keyValuePair];
    
    if (successBlock || failureBlock) {
        if (!pendingSendTagCallbacks)
            pendingSendTagCallbacks = [[NSMutableArray alloc] init];
        OSPendingCallbacks* pendingCallbacks = [OSPendingCallbacks alloc];
        pendingCallbacks.successBlock = successBlock;
        pendingCallbacks.failureBlock = failureBlock;
        [pendingSendTagCallbacks addObject:pendingCallbacks];
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendTagsToServer) object:nil];
    
    // Can't send tags yet as their isn't a player_id.
    //   tagsToSend will be sent with the POST create player call later in this case.
    if (self.currentSubscriptionState.userId)
       [OneSignalHelper performSelector:@selector(sendTagsToServer) onMainThreadOnObject:self withObject:nil afterDelay:5];
}

// Called only with a delay to batch network calls.
+ (void) sendTagsToServer {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    if (!tagsToSend)
        return;
    
    NSDictionary* nowSendingTags = tagsToSend;
    tagsToSend = nil;
    
    NSArray* nowProcessingCallbacks = pendingSendTagCallbacks;
    pendingSendTagCallbacks = nil;
    
    NSMutableDictionary *requests = [NSMutableDictionary new];
    
    requests[@"push"] = [OSRequestSendTagsToServer withUserId:self.currentSubscriptionState.userId appId:self.app_id tags:nowSendingTags networkType:[OneSignalHelper getNetType] withEmailAuthHashToken:nil];
    
    if (self.currentEmailSubscriptionState.emailUserId && (self.currentEmailSubscriptionState.requiresEmailAuth == false || self.currentEmailSubscriptionState.emailAuthCode))
        requests[@"email"] = [OSRequestSendTagsToServer withUserId:self.currentEmailSubscriptionState.emailUserId appId:self.app_id tags:nowSendingTags networkType:[OneSignalHelper getNetType] withEmailAuthHashToken:self.currentEmailSubscriptionState.emailAuthCode];
    
    [OneSignalClient.sharedClient executeSimultaneousRequests:requests withSuccess:^(NSDictionary<NSString *, NSDictionary *> *results) {
        //the tags for email & push are identical so it doesn't matter what we return in the success block
        
        NSDictionary *resultTags = results[@"push"];
        
        if (!resultTags)
            resultTags = results[@"email"];
        
        if (nowProcessingCallbacks)
            for (OSPendingCallbacks *callbackSet in nowProcessingCallbacks)
                if (callbackSet.successBlock)
                    callbackSet.successBlock(resultTags);
        
    } onFailure:^(NSDictionary<NSString *, NSError *> *errors) {
        if (nowProcessingCallbacks) {
            for (OSPendingCallbacks *callbackSet in nowProcessingCallbacks) {
                if (callbackSet.failureBlock) {
                    callbackSet.failureBlock((NSError *)(errors[@"push"] ?: errors[@"email"]));
                }
            }
        }
    }];
}

+ (void)sendTag:(NSString*)key value:(NSString*)value {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"sendTag:value:"])
        return;
    
    [self sendTag:key value:value onSuccess:nil onFailure:nil];
}

+ (void)sendTag:(NSString*)key value:(NSString*)value onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"sendTag:value:onSuccess:onFailure:"])
        return;
    
    [self sendTags:[NSDictionary dictionaryWithObjectsAndKeys: value, key, nil] onSuccess:successBlock onFailure:failureBlock];
}

+ (void)getTags:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"getTags:onFailure:"])
        return;
    
    if (!self.currentSubscriptionState.userId) {
        pendingGetTagsSuccessBlock = successBlock;
        pendingGetTagsFailureBlock = failureBlock;
        return;
    }
    
    [OneSignalClient.sharedClient executeRequest:[OSRequestGetTags withUserId:self.currentSubscriptionState.userId appId:self.app_id] onSuccess:^(NSDictionary *result) {
        successBlock([result objectForKey:@"tags"]);
    } onFailure:failureBlock];
    
}

+ (void)getTags:(OSResultSuccessBlock)successBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"getTags:"])
        return;
    
    [self getTags:successBlock onFailure:nil];
}


+ (void)deleteTag:(NSString*)key onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"deleteTag:onSuccess:onFailure:"])
        return;
    
    [self deleteTags:@[key] onSuccess:successBlock onFailure:failureBlock];
}

+ (void)deleteTag:(NSString*)key {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"deleteTag:"])
        return;
    
    [self deleteTags:@[key] onSuccess:nil onFailure:nil];
}

+ (void)deleteTags:(NSArray*)keys {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"deleteTags:"])
        return;
    
    [self deleteTags:keys onSuccess:nil onFailure:nil];
}

+ (void)deleteTagsWithJsonString:(NSString*)jsonString {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"deleteTagsWithJsonString:"])
        return;
    
    NSError* jsonError;
    
    NSData* data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSArray* keys = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    if (jsonError == nil)
        [self deleteTags:keys];
    else {
        onesignal_Log(ONE_S_LL_WARN,[NSString stringWithFormat: @"deleteTags JSON Parse Error: %@", jsonError]);
        onesignal_Log(ONE_S_LL_WARN,[NSString stringWithFormat: @"deleteTags JSON Parse Error, JSON: %@", jsonString]);
    }
}

+ (void)deleteTags:(NSArray*)keys onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    NSMutableDictionary* tags = [[NSMutableDictionary alloc] init];
    
    for(NSString* key in keys) {
        if (tagsToSend && tagsToSend[key]) {
            if (![tagsToSend[key] isEqual:@""])
                [tagsToSend removeObjectForKey:key];
        }
        else
            tags[key] = @"";
    }
    
    [self sendTags:tags onSuccess:successBlock onFailure:failureBlock];
}


+ (void)postNotification:(NSDictionary*)jsonData {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"postNotification:"])
        return;
    
    [self postNotification:jsonData onSuccess:nil onFailure:nil];
}

+ (void)postNotification:(NSDictionary*)jsonData onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"postNotification:onSuccess:onFailure:"])
        return;
    
    NSMutableDictionary *json = [jsonData mutableCopy];
    
    [OneSignal convertDatesToISO8061Strings:json]; //convert any dates to NSString's
    
    [OneSignalClient.sharedClient executeRequest:[OSRequestPostNotification withAppId:self.app_id withJson:json] onSuccess:^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSData* jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            NSString* jsonResultsString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            
            onesignal_Log(ONE_S_LL_DEBUG, [NSString stringWithFormat: @"HTTP create notification success %@", jsonResultsString]);
            if (successBlock)
                successBlock(result);
        });
    } onFailure:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onesignal_Log(ONE_S_LL_ERROR, @"Create notification failed");
            onesignal_Log(ONE_S_LL_INFO, [NSString stringWithFormat: @"%@", error]);
            if (failureBlock)
                failureBlock(error);
        });
    }];
}

+ (void)postNotificationWithJsonString:(NSString*)jsonString onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"postNotificationWithJsonString:onSuccess:onFailure:"])
        return;
    
    NSError* jsonError;
    
    NSData* data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* jsonData = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
    if (jsonError == nil && jsonData != nil)
        [self postNotification:jsonData onSuccess:successBlock onFailure:failureBlock];
    else {
        onesignal_Log(ONE_S_LL_WARN, [NSString stringWithFormat: @"postNotification JSON Parse Error: %@", jsonError]);
        onesignal_Log(ONE_S_LL_WARN, [NSString stringWithFormat: @"postNotification JSON Parse Error, JSON: %@", jsonString]);
    }
}

+ (void)convertDatesToISO8061Strings:(NSMutableDictionary *)dictionary {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    NSLocale *enUSPOSIXLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    [dateFormatter setLocale:enUSPOSIXLocale];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
    
    for (NSString *key in dictionary.allKeys) {
        id value = dictionary[key];
        
        if ([value isKindOfClass:[NSDate class]])
            dictionary[key] = [dateFormatter stringFromDate:(NSDate *)value];
    }
}

+ (NSString*)parseNSErrorAsJsonString:(NSError*)error {
    NSString* jsonResponse;
    
    if (error.userInfo && error.userInfo[@"returned"]) {
        @try {
            NSData* jsonData = [NSJSONSerialization dataWithJSONObject:error.userInfo[@"returned"] options:0 error:nil];
            jsonResponse = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        } @catch(NSException* e) {
            onesignal_Log(ONE_S_LL_ERROR, [NSString stringWithFormat:@"%@", e]);
            onesignal_Log(ONE_S_LL_ERROR, [NSString stringWithFormat:@"%@",  [NSThread callStackSymbols]]);
            jsonResponse = @"{\"error\": \"Unknown error parsing error response.\"}";
        }
    }
    else
        jsonResponse = @"{\"error\": \"HTTP no response error\"}";
    
    return jsonResponse;
}

+ (void)enableInAppLaunchURL:(NSNumber*)enable {
    [[NSUserDefaults standardUserDefaults] setObject:enable forKey:@"ONESIGNAL_INAPP_LAUNCH_URL"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)setSubscription:(BOOL)enable {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"setSubscription:"])
        return;
    
    NSString* value = nil;
    if (!enable)
        value = @"no";

    [[NSUserDefaults standardUserDefaults] setObject:value forKey:SUBSCRIPTION];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    shouldDelaySubscriptionUpdate = true;
    
    self.currentSubscriptionState.userSubscriptionSetting = enable;
    
    if (app_id)
        [OneSignal sendNotificationTypesUpdate];
}


+ (void)setLocationShared:(BOOL)enable {
   mShareLocation = enable;
}

+ (void) promptLocation {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"promptLocation"])
        return;
    
    [OneSignalLocation getLocation:true];
}


+ (void) handleDidFailRegisterForRemoteNotification:(NSError*)err {
    waitingForApnsResponse = false;
    
    if (err.code == 3000) {
        if ([((NSString*)[err.userInfo objectForKey:NSLocalizedDescriptionKey]) rangeOfString:@"no valid 'aps-environment'"].location != NSNotFound) {
            // User did not enable push notification capability
            [OneSignal setSubscriptionErrorStatus:ERROR_PUSH_CAPABLILITY_DISABLED];
            [OneSignal onesignal_Log:ONE_S_LL_ERROR message:@"ERROR! 'Push Notification' capability not turned on! Enable it in Xcode under 'Project Target' -> Capability."];
        }
        else {
            [OneSignal setSubscriptionErrorStatus:ERROR_PUSH_OTHER_3000_ERROR];
            [OneSignal onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat:@"ERROR! Unknown 3000 error returned from APNs when getting a push token: %@", err]];
        }
    }
    else if (err.code == 3010) {
        [OneSignal setSubscriptionErrorStatus:ERROR_PUSH_SIMULATOR_NOT_SUPPORTED];
        [OneSignal onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat:@"Error! iOS Simulator does not support push! Please test on a real iOS device. Error: %@", err]];
    }
    else {
        [OneSignal setSubscriptionErrorStatus:ERROR_PUSH_UNKNOWN_APNS_ERROR];
        [OneSignal onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat:@"Error registering for Apple push notifications! Error: %@", err]];
    }
    
    // iOS 7
    [self.osNotificationSettings onAPNsResponse:false];
}

+ (void)updateDeviceToken:(NSString*)deviceToken onSuccess:(OSResultSuccessBlock)successBlock onFailure:(OSFailureBlock)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"updateDeviceToken:onSuccess:onFailure:"])
        return;
    
    onesignal_Log(ONE_S_LL_VERBOSE, @"updateDeviceToken:onSuccess:onFailure:");
    
    // iOS 7
    [self.osNotificationSettings onAPNsResponse:true];
    
    // Do not block next registration as there's a new token in hand
    nextRegistrationIsHighPriority = ![deviceToken isEqualToString:self.currentSubscriptionState.pushToken] || [self getNotificationTypes] != mLastNotificationTypes;
    
    if (!self.currentSubscriptionState.userId) {
        self.currentSubscriptionState.pushToken = deviceToken;
        tokenUpdateSuccessBlock = successBlock;
        tokenUpdateFailureBlock = failureBlock;
        
        // iOS 8+ - We get a token right away but give the user 30 sec to respond notification permission prompt.
        // The goal is to only have 1 server call.
        [self.osNotificationSettings getNotificationPermissionState:^(OSPermissionState *status) {
            if (status.answeredPrompt || status.provisional) {
                [OneSignal registerUser];
            } else {
                [self registerUserAfterDelay];
            }
        }];
        return;
    }
    
    if ([deviceToken isEqualToString:self.currentSubscriptionState.pushToken]) {
        if (successBlock)
            successBlock(nil);
        return;
    }
    
    self.currentSubscriptionState.pushToken = deviceToken;
    
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:@"Calling OneSignal PUT updated pushToken!"];
    
    [OneSignalClient.sharedClient executeRequest:[OSRequestUpdateDeviceToken withUserId:self.currentSubscriptionState.userId appId:self.app_id deviceToken:deviceToken notificationTypes:@([self getNotificationTypes]) withParentId:nil emailAuthToken:nil email: nil] onSuccess:successBlock onFailure:failureBlock];
    
    [self fireIdsAvailableCallback];
}

// Set to yes whenever a high priority registration fails ... need to make the next one a high priority to disregard the timer delay
bool nextRegistrationIsHighPriority = NO;

+ (BOOL)isHighPriorityCall {
    return !self.currentSubscriptionState.userId || nextRegistrationIsHighPriority;
}

static BOOL waitingForOneSReg = false;

//needed so that tests can make sure registerUserInternal executes
+ (void)setNextRegistrationHighPriority:(BOOL)highPriority {
    nextRegistrationIsHighPriority = highPriority;
}


+ (void)updateLastSessionDateTime {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [[NSUserDefaults standardUserDefaults] setDouble:now forKey:@"GT_LAST_CLOSED_TIME"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+(BOOL)shouldRegisterNow {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return false;
    
    if (waitingForOneSReg)
        return false;
    
    // Figure out if should pass or not
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval lastTimeClosed = [[NSUserDefaults standardUserDefaults] doubleForKey:@"GT_LAST_CLOSED_TIME"];
    if (!lastTimeClosed) {
        [self updateLastSessionDateTime];
        return true;
    }
    
    if ([self isHighPriorityCall])
        return true;
    
    // Make sure last time we closed app was more than 30 secs ago
    const int minTimeThreshold = 30;
    NSTimeInterval delta = now - lastTimeClosed;
    return delta > minTimeThreshold;
}


+ (void)registerUserAfterDelay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(registerUser) object:nil];
    [OneSignalHelper performSelector:@selector(registerUser) onMainThreadOnObject:self withObject:nil afterDelay:reattemptRegistrationInterval];
}

static dispatch_queue_t serialQueue;

+ (dispatch_queue_t) getRegisterQueue {
    return serialQueue;
}

+ (void)registerUser {
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    // We should delay registration if we are waiting on APNS
    // But if APNS hasn't responded within 30 seconds,
    // we should continue and register the user.
    if (waitingForApnsResponse && initializationTime && [[NSDate date] timeIntervalSinceDate:initializationTime] < maxApnsWait) {
        [self registerUserAfterDelay];
        return;
    }
    
    if (!serialQueue)
        serialQueue = dispatch_queue_create("com.onesignal.regiseruser", DISPATCH_QUEUE_SERIAL);
   
   dispatch_async(serialQueue, ^{
        [self registerUserInternal];
    });
}

+ (void)registerUserInternal {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    // Make sure we only call create or on_session once per open of the app.
    if (![self shouldRegisterNow])
        return;
    
    [OneSignalTrackFirebaseAnalytics trackInfluenceOpenEvent];
    
    waitingForOneSReg = true;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(registerUser) object:nil];
    
    let infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString* build = infoDictionary[(NSString*)kCFBundleVersionKey];
    
    struct utsname systemInfo;
    uname(&systemInfo);
    let deviceModel = [NSString stringWithCString:systemInfo.machine
                                         encoding:NSUTF8StringEncoding];
    
    let dataDic = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                   app_id, @"app_id",
                   [[UIDevice currentDevice] systemVersion], @"device_os",
                   [NSNumber numberWithInt:(int)[[NSTimeZone localTimeZone] secondsFromGMT]], @"timezone",
                   [NSNumber numberWithInt:0], @"device_type",
                   [[[UIDevice currentDevice] identifierForVendor] UUIDString], @"ad_id",
                   ONESIGNAL_VERSION, @"sdk",
                   nil];
    
    // should be set to true even before the API request is finished
    performedOnSessionRequest = true;
    
    if (pendingExternalUserId && ![self.existingExternalUserId isEqualToString:pendingExternalUserId])
        dataDic[@"external_user_id"] = pendingExternalUserId;
    
    pendingExternalUserId = nil;
    
    if (deviceModel)
        dataDic[@"device_model"] = deviceModel;
    
    if (build)
        dataDic[@"game_version"] = build;
    
    if ([OneSignalJailbreakDetection isJailbroken])
        dataDic[@"rooted"] = @YES;
    
    dataDic[@"net_type"] = [OneSignalHelper getNetType];
    
    if (!self.currentSubscriptionState.userId) {
        dataDic[@"sdk_type"] = mSDKType;
        dataDic[@"ios_bundle"] = [[NSBundle mainBundle] bundleIdentifier];
    }
    
    
    let preferredLanguages = [NSLocale preferredLanguages];
    if (preferredLanguages && preferredLanguages.count > 0)
        dataDic[@"language"] = [preferredLanguages objectAtIndex:0];
    
    let notificationTypes = [self getNotificationTypes];
    mLastNotificationTypes = notificationTypes;
    dataDic[@"notification_types"] = [NSNumber numberWithInt:notificationTypes];
    
    let ASIdentifierManagerClass = NSClassFromString(@"ASIdentifierManager");
    if (ASIdentifierManagerClass) {
        id asIdManager = [ASIdentifierManagerClass valueForKey:@"sharedManager"];
        if ([[asIdManager valueForKey:@"advertisingTrackingEnabled"] isEqual:[NSNumber numberWithInt:1]])
            dataDic[@"as_id"] = [[asIdManager valueForKey:@"advertisingIdentifier"] UUIDString];
        else
            dataDic[@"as_id"] = @"OptedOut";
    }
    
    let CTTelephonyNetworkInfoClass = NSClassFromString(@"CTTelephonyNetworkInfo");
    if (CTTelephonyNetworkInfoClass) {
        id instance = [[CTTelephonyNetworkInfoClass alloc] init];
        let carrierName = (NSString *)[[instance valueForKey:@"subscriberCellularProvider"] valueForKey:@"carrierName"];
        
        if (carrierName) {
            dataDic[@"carrier"] = carrierName;
        }
    }
    
    let releaseMode = [OneSignalMobileProvision releaseMode];
    if (releaseMode == UIApplicationReleaseDev || releaseMode == UIApplicationReleaseAdHoc || releaseMode == UIApplicationReleaseWildcard)
        dataDic[@"test_type"] = [NSNumber numberWithInt:releaseMode];
    
    NSArray* nowProcessingCallbacks;
    
    if (tagsToSend) {
        dataDic[@"tags"] = tagsToSend;
        tagsToSend = nil;
        
        nowProcessingCallbacks = pendingSendTagCallbacks;
        pendingSendTagCallbacks = nil;
    }
    
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:@"Calling OneSignal create/on_session"];
    
    
    if (mShareLocation && [OneSignalLocation lastLocation]) {
        dataDic[@"lat"] = [NSNumber numberWithDouble:[OneSignalLocation lastLocation]->cords.latitude];
        dataDic[@"long"] = [NSNumber numberWithDouble:[OneSignalLocation lastLocation]->cords.longitude];
        dataDic[@"loc_acc_vert"] = [NSNumber numberWithDouble:[OneSignalLocation lastLocation]->verticalAccuracy];
        dataDic[@"loc_acc"] = [NSNumber numberWithDouble:[OneSignalLocation lastLocation]->horizontalAccuracy];
        [OneSignalLocation clearLastLocation];
    }
    
    
    let pushDataDic = (NSMutableDictionary *)[dataDic mutableCopy];
    pushDataDic[@"identifier"] = self.currentSubscriptionState.pushToken;
    
    let requests = [NSMutableDictionary new];
    requests[@"push"] = [OSRequestRegisterUser withData:pushDataDic userId:self.currentSubscriptionState.userId];
    
    if (self.currentEmailSubscriptionState.emailUserId && (!self.currentEmailSubscriptionState.requiresEmailAuth || self.currentEmailSubscriptionState.emailAuthCode)) {
        let emailDataDic = (NSMutableDictionary *)[dataDic mutableCopy];
        emailDataDic[@"device_type"] = @11;
        emailDataDic[@"email_auth_hash"] = self.currentEmailSubscriptionState.emailAuthCode;
        
        requests[@"email"] = [OSRequestRegisterUser withData:emailDataDic userId:self.currentEmailSubscriptionState.emailUserId];
    }
    
    [OneSignalClient.sharedClient executeSimultaneousRequests:requests withSuccess:^(NSDictionary<NSString *, NSDictionary *> *results) {
        waitingForOneSReg = false;
        
        // Success, no more high priority
        nextRegistrationIsHighPriority = NO;
        
        [self updateLastSessionDateTime];
        
        //update email player ID
        if (results[@"email"] && results[@"email"][@"id"]) {
            
            // check to see if the email player_id or email_auth_token are different from what were previously saved
            // if so, we should update the server with this change
            
            if (self.currentEmailSubscriptionState.emailUserId && ![self.currentEmailSubscriptionState.emailUserId isEqualToString:results[@"email"][@"id"]] && self.currentEmailSubscriptionState.emailAuthCode) {
                [self emailChangedWithNewEmailPlayerId:results[@"email"][@"id"]];
            }
            
            self.currentEmailSubscriptionState.emailUserId = results[@"email"][@"id"];
            [[NSUserDefaults standardUserDefaults] setObject:self.currentEmailSubscriptionState.emailUserId forKey:EMAIL_USERID];
            //NSUserDefaults Synchronize: called after the next if-statement
        }
        
        //update push player id
        if (results.count > 0 && results[@"push"][@"id"]) {
            self.currentSubscriptionState.userId = results[@"push"][@"id"];
            
            if (delayedEmailParameters) {
                //a call to setEmail: was delayed because the push player_id did not exist yet
                [self setEmail:delayedEmailParameters.email withEmailAuthHashToken:delayedEmailParameters.authToken withSuccess:delayedEmailParameters.successBlock withFailure:delayedEmailParameters.failureBlock];
                delayedEmailParameters = nil;
            }
            
            [[NSUserDefaults standardUserDefaults] setObject:self.currentSubscriptionState.userId forKey:USERID];
            //NSUserDefaults Synchronize: called after this if-statement
            
            if (nowProcessingCallbacks) {
                for (OSPendingCallbacks *callbackSet in nowProcessingCallbacks) {
                    if (callbackSet.successBlock)
                        callbackSet.successBlock(dataDic[@"tags"]);
                }
            }
            
            if (self.currentSubscriptionState.pushToken)
                [self updateDeviceToken:self.currentSubscriptionState.pushToken
                              onSuccess:tokenUpdateSuccessBlock
                              onFailure:tokenUpdateFailureBlock];
            
            if (tagsToSend)
                [self performSelector:@selector(sendTagsToServer) withObject:nil afterDelay:5];
            
            // try to send location
            [OneSignalLocation sendLocation];
            
            if (emailToSet) {
                [OneSignal syncHashedEmail:emailToSet];
                emailToSet = nil;
            }
            
            [self fireIdsAvailableCallback];
            
            [self sendNotificationTypesUpdate];
            
            if (pendingGetTagsSuccessBlock) {
                [OneSignal getTags:pendingGetTagsSuccessBlock onFailure:pendingGetTagsFailureBlock];
                pendingGetTagsSuccessBlock = nil;
                pendingGetTagsFailureBlock = nil;
            }
            
        }
        
        // If the external user ID was sent as part of this request, we need to save it
        // The 'successfullySentExternalUserId' method already calls NSUserDefaults synchronize
        // so there is no need to call it again
        if (dataDic[@"external_user_id"])
            [self successfullySentExternalUserId:dataDic[@"external_user_id"]];
        else
            [[NSUserDefaults standardUserDefaults] synchronize];
        
    } onFailure:^(NSDictionary<NSString *, NSError *> *errors) {
        waitingForOneSReg = false;
        
        for (NSString *key in @[@"push", @"email"])
            [OneSignal onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat: @"Encountered error during %@ registration with OneSignal: %@", key, errors[key]]];
        
        //If the failed registration is priority, force the next one to be a high priority
        nextRegistrationIsHighPriority = YES;
        
        let error = (NSError *)(errors[@"push"] ?: errors[@"email"]);
        
        if (nowProcessingCallbacks) {
            for (OSPendingCallbacks *callbackSet in nowProcessingCallbacks) {
                if (callbackSet.failureBlock)
                    callbackSet.failureBlock(error);
            }
        }
    }];
}

+(NSString*)getUsableDeviceToken {
    if (mSubscriptionStatus < -1)
        return NULL;
    
    return self.currentPermissionState.accepted ? self.currentSubscriptionState.pushToken : NULL;
}

// Updates the server with the new user's notification setting or subscription status changes
+ (BOOL) sendNotificationTypesUpdate {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return false;
    
    // User changed notification settings for the app.
    if ([self getNotificationTypes] != -1 && self.currentSubscriptionState.userId && mLastNotificationTypes != [self getNotificationTypes]) {
        if (!self.currentSubscriptionState.pushToken) {
            if ([self registerForAPNsToken])
                return true;
        }
        
        mLastNotificationTypes = [self getNotificationTypes];
        
        //delays observer update until the OneSignal server is notified
        shouldDelaySubscriptionUpdate = true;
        
        [OneSignalClient.sharedClient executeRequest:[OSRequestUpdateNotificationTypes withUserId:self.currentSubscriptionState.userId appId:self.app_id notificationTypes:@([self getNotificationTypes])] onSuccess:^(NSDictionary *result) {
            
            shouldDelaySubscriptionUpdate = false;
            
            if (self.currentSubscriptionState.delayedObserverUpdate)
                [self.currentSubscriptionState setAccepted:[self getNotificationTypes] > 0];
            
        } onFailure:nil];
        
        if ([self getUsableDeviceToken])
            [self fireIdsAvailableCallback];
        
        return true;
    }
    
    return false;
}

+ (void)sendPurchases:(NSArray*)purchases {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    if (!self.currentSubscriptionState.userId)
        return;
    
    let requests = [NSMutableDictionary new];
    
    requests[@"push"] = [OSRequestSendPurchases withUserId:self.currentSubscriptionState.userId appId:self.app_id withPurchases:purchases];
    
    if (self.currentEmailSubscriptionState.emailUserId)
        requests[@"email"] = [OSRequestSendPurchases withUserId:self.currentEmailSubscriptionState.emailUserId emailAuthToken:self.currentEmailSubscriptionState.emailAuthCode appId:self.app_id withPurchases:purchases];
    
    [OneSignalClient.sharedClient executeSimultaneousRequests:requests withSuccess:nil onFailure:nil];
}


static NSString *_lastAppActiveMessageId;
+ (void)setLastAppActiveMessageId:(NSString*)value { _lastAppActiveMessageId = value; }

static NSString *_lastnonActiveMessageId;
+ (void)setLastnonActiveMessageId:(NSString*)value { _lastnonActiveMessageId = value; }

+ (void)displayTypeForNotificationPayload:(NSDictionary *)payload withCompletion:(OSNotificationDisplayTypeResponse)completion {
    [OneSignalHelper runOnMainThread:^{
        if (!_displayTypeMap)
            _displayTypeMap = [NSMutableDictionary new];
        
        if (!_pendingDisplayTypeCallbacks)
            _pendingDisplayTypeCallbacks = [NSMutableDictionary new];
        
        var type = self.inFocusDisplayType;
        
        // check to make sure the app is in focus and it's a OneSignal notification
        if (![OneSignalHelper isOneSignalPayload:payload]
            || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            completion(type);
            return;
        }
        
        let osPayload = [OSNotificationPayload parseWithApns:payload];
        
        let notificationId = osPayload.notificationID;
        
        // Prevent calling the delegate multiple times for the same payload
        // Checks to see if there is a pending delegate request
        if (_pendingDisplayTypeCallbacks[notificationId]) {
            [_pendingDisplayTypeCallbacks[notificationId] addObject:completion];
            // checks to see if the delegate already responded for this notification
        } else if (_displayTypeMap[osPayload.notificationID]) {
            type = (OSNotificationDisplayType)[_displayTypeMap[osPayload.notificationID] intValue];
            completion(type);
        } else if (_displayDelegate) {
            NSMutableArray *callbacks = [NSMutableArray new];
            [callbacks addObject:completion];
            [_pendingDisplayTypeCallbacks setObject:callbacks forKey:notificationId];
            
            NSTimer *watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:CUSTOM_DISPLAY_TYPE_TIMEOUT
                                                                      target:self
                                                                    selector:@selector(watchdogTimerFired:)
                                                                    userInfo:notificationId
                                                                     repeats:false];
            
            [_displayDelegate willPresentInFocusNotificationWithPayload:osPayload withCompletion:^(OSNotificationDisplayType displayType) {
                [OneSignalHelper runOnMainThread:^{
                    NSMutableArray<OSNotificationDisplayTypeResponse> *callbacks = _pendingDisplayTypeCallbacks[notificationId];
                    
                    if (!callbacks || callbacks.count == 0)
                        return;
                    
                    [watchdogTimer invalidate];
                    [_pendingDisplayTypeCallbacks removeObjectForKey:notificationId];
                    _displayTypeMap[notificationId] = @((int)displayType);
                    
                    for (OSNotificationDisplayTypeResponse callback in callbacks)
                        callback(displayType);
                }];
            }];
        } else {
            // No delegate is set; uses the main display type set with OneSignal.setInFocusDisplayType()
            _displayTypeMap[notificationId] = @((int)type);
            completion(type);
        }
    }];
}

// If this is called, it means OSNotificationDisplayTypeDelegate did not execute the callback
// within the max time range, and timed out. We must display the notification anyways
// using the default display type to avoid dropping notifications.
+ (void)watchdogTimerFired:(NSTimer *)timer {
    NSString *notificationId = (NSString *)timer.userInfo;
    NSMutableArray<OSNotificationDisplayTypeResponse> *callbacks = _pendingDisplayTypeCallbacks[notificationId];
    
    // Check just in case the app called the callback just as this timer fired
    if (!callbacks || callbacks.count == 0)
        return;
    
    [_pendingDisplayTypeCallbacks removeObjectForKey:notificationId];
    
    _displayTypeMap[notificationId] = @(_inFocusDisplayType);
    
    for (OSNotificationDisplayTypeResponse completion in callbacks)
        completion(_inFocusDisplayType);
}

// Entry point for the following:
//  - 1. (iOS all) - Opening notifications
//  - 2. Notification received
//    - 2A. iOS 9  - Notification received while app is in focus.
//    - 2B. iOS 10 - Notification received/displayed while app is in focus.
+ (void)notificationReceived:(NSDictionary*)messageDict isActive:(BOOL)isActive wasOpened:(BOOL)opened {
    if ([OneSignal shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    if (!app_id)
        return;
    
    // This method should not continue to be executed for non-OS push notifications
    if (![OneSignalHelper isOneSignalPayload:messageDict])
        return;
    
    onesignal_Log(ONE_S_LL_VERBOSE, @"notificationOpened:isActive called!");
    
    NSDictionary* customDict = [messageDict objectForKey:@"os_data"] ?: [messageDict objectForKey:@"custom"];
    
    // Should be called first, other methods relay on this global state below.
    [OneSignalHelper lastMessageReceived:messageDict];
    
    if (isActive) {
        // Prevent duplicate calls
        let newId = [self checkForProcessedDups:customDict lastMessageId:_lastAppActiveMessageId];
        if ([@"dup" isEqualToString:newId])
            return;
        if (newId)
            _lastAppActiveMessageId = newId;
        
        [self displayTypeForNotificationPayload:messageDict withCompletion:^(OSNotificationDisplayType displayType) {
            let inAppAlert = (displayType == OSNotificationDisplayTypeInAppAlert);
            
            // Make sure it is not a silent one do display, if inAppAlerts are enabled
            if (inAppAlert && ![OneSignalHelper isRemoteSilentNotification:messageDict]) {
                [OneSignalAlertView showInAppAlert:messageDict];
                return;
            }
            
            // App is active and a notification was received without inApp display. Display type is none or notification
            // Call Received Block
            [OneSignalHelper handleNotificationReceived:displayType];
            
            if (opened)
                [self openedNotificationWithDisplayType:displayType withPayload:messageDict isActive:isActive];
        }];
    } else {
        // Prevent duplicate calls
        let newId = [self checkForProcessedDups:customDict lastMessageId:_lastnonActiveMessageId];
        if ([@"dup" isEqualToString:newId])
            return;
        if (newId)
            _lastnonActiveMessageId = newId;
        
        if (opened)
            [self openedNotificationWithDisplayType:OneSignal.inFocusDisplayType withPayload:messageDict isActive:isActive];
    }
}

+ (void)openedNotificationWithDisplayType:(OSNotificationDisplayType)displayType withPayload:(NSDictionary *)payload isActive:(BOOL)isActive {
    //app was in background / not running and opened due to a tap on a notification or an action check what type
    OSNotificationActionType type = OSNotificationActionTypeOpened;
    
    if (payload[@"custom"][@"a"][@"actionSelected"] || payload[@"actionSelected"])
        type = OSNotificationActionTypeActionTaken;
    
    // Call Action Block
    [OneSignal handleNotificationOpened:payload isActive:isActive actionType:type displayType:displayType];
}

+ (NSString*) checkForProcessedDups:(NSDictionary*)customDict lastMessageId:(NSString*)lastMessageId {
    if (customDict && customDict[@"i"]) {
        NSString* currentNotificationId = customDict[@"i"];
        if ([currentNotificationId isEqualToString:lastMessageId])
            return @"dup";
        return customDict[@"i"];
    }
    return nil;
}

+ (void)handleNotificationOpened:(NSDictionary*)messageDict
                        isActive:(BOOL)isActive
                      actionType:(OSNotificationActionType)actionType
                     displayType:(OSNotificationDisplayType)displayType {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"handleNotificationOpened:isActive:actionType:displayType:"])
        return;
    
    NSDictionary* customDict = [messageDict objectForKey:@"custom"] ?: [messageDict objectForKey:@"os_data"];
    
    // Notify backend that user opened the notification
    NSString* messageId = [customDict objectForKey:@"i"];
    [OneSignal submitNotificationOpened:messageId];
    
    //Try to fetch the open url to launch
    [OneSignal launchWebURL:[customDict objectForKey:@"u"]];
    
    [self clearBadgeCount:true];
    
    NSString* actionID = NULL;
    if (actionType == OSNotificationActionTypeActionTaken) {
        actionID = messageDict[@"custom"][@"a"][@"actionSelected"];
        if(!actionID)
            actionID = messageDict[@"actionSelected"];
    }
    
    //Call Action Block
    [OneSignalHelper lastMessageReceived:messageDict];
    
    //ensures that if the app is open and display type == none, the handleNotificationAction block does not get called
    if (displayType != OSNotificationDisplayTypeNone || (displayType == OSNotificationDisplayTypeNone && !isActive)) {
        [OneSignalHelper handleNotificationAction:actionType actionID:actionID displayType:displayType];
    }
}

+ (BOOL)shouldPromptToShowURL {
    return promptBeforeOpeningPushURLs;
}

+ (void)launchWebURL:(NSString*)openUrl {
    
    NSString* toOpenUrl = [OneSignalHelper trimURLSpacing:openUrl];
    
    if (toOpenUrl && [OneSignalHelper verifyURL:toOpenUrl]) {
        NSURL *url = [NSURL URLWithString:toOpenUrl];
        // Give the app resume animation time to finish when tapping on a notification from the notification center.
        // Isn't a requirement but improves visual flow.
        [OneSignalHelper performSelector:@selector(displayWebView:) withObject:url afterDelay:0.5];
    }
    
}

+ (void)submitNotificationOpened:(NSString*)messageId {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    //(DUPLICATE Fix): Make sure we do not upload a notification opened twice for the same messageId
    //Keep track of the Id for the last message sent
    NSString* lastMessageId = [[NSUserDefaults standardUserDefaults] objectForKey:@"GT_LAST_MESSAGE_OPENED_"];
    //Only submit request if messageId not nil and: (lastMessage is nil or not equal to current one)
    if(messageId && (!lastMessageId || ![lastMessageId isEqualToString:messageId])) {
        [OneSignalClient.sharedClient executeRequest:[OSRequestSubmitNotificationOpened withUserId:self.currentSubscriptionState.userId appId:self.app_id wasOpened:YES messageId:messageId] onSuccess:nil onFailure:nil];
        [[NSUserDefaults standardUserDefaults] setObject:messageId forKey:@"GT_LAST_MESSAGE_OPENED_"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
    
+ (BOOL) clearBadgeCount:(BOOL)fromNotifOpened {
    
    NSNumber *disableBadgeNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:ONESIGNAL_DISABLE_BADGE_CLEARING];
    
    if (disableBadgeNumber)
        disableBadgeClearing = [disableBadgeNumber boolValue];
    else
        disableBadgeClearing = NO;
    
    if (disableBadgeClearing ||
        ([OneSignalHelper isIOSVersionGreaterOrEqual:8] && [self.osNotificationSettings getNotificationPermissionState].notificationTypes & NOTIFICATION_TYPE_BADGE) == 0)
        return false;
    
    bool wasBadgeSet = [UIApplication sharedApplication].applicationIconBadgeNumber > 0;
    
    if ((!(NSFoundationVersionNumber > NSFoundationVersionNumber_iOS_7_1) && fromNotifOpened) || wasBadgeSet) {
        // Clear badges and notifications from this app.
        // Setting to 1 then 0 was needed to clear the notifications on iOS 6 & 7. (Otherwise you can click the notification multiple times.)
        // iOS 8+ auto dismisses the notification you tap on so only clear the badge (and notifications [side-effect]) if it was set.
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:1];
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    }
    
    return wasBadgeSet;
}

+ (int) getNotificationTypes {
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message: [NSString stringWithFormat:@"getNotificationTypes:mSubscriptionStatus: %d", mSubscriptionStatus]];
    
    if (mSubscriptionStatus < -9)
        return mSubscriptionStatus;
    
    if (waitingForApnsResponse && !self.currentSubscriptionState.pushToken)
        return ERROR_PUSH_DELEGATE_NEVER_FIRED;
    
    OSPermissionState* permissionStatus = [self.osNotificationSettings getNotificationPermissionState];
    
    //only return the error statuses if not provisional
    if (!permissionStatus.provisional && !permissionStatus.hasPrompted)
        return ERROR_PUSH_NEVER_PROMPTED;
    
    if (!permissionStatus.provisional && !permissionStatus.answeredPrompt)
        return ERROR_PUSH_PROMPT_NEVER_ANSWERED;
    
    if (!self.currentSubscriptionState.userSubscriptionSetting)
        return -2;

    return permissionStatus.notificationTypes;
}

+ (void)setSubscriptionErrorStatus:(int)errorType {
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message: [NSString stringWithFormat:@"setSubscriptionErrorStatus: %d", errorType]];
    
    mSubscriptionStatus = errorType;
    if (self.currentSubscriptionState.userId)
        [self sendNotificationTypesUpdate];
    else
        [self registerUser];
}

// iOS 8.0+ only
//    User just responed to the iOS native notification permission prompt.
//    Also extra calls to registerUserNotificationSettings will fire this without prompting again.
+ (void)updateNotificationTypes:(int)notificationTypes {
    
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:[NSString stringWithFormat:@"updateNotificationTypes called: %d", notificationTypes]];
    
    if (![OneSignalHelper isIOSVersionGreaterOrEqual:10]) {
        NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
        [userDefaults setBool:true forKey:@"OS_NOTIFICATION_PROMPT_ANSWERED"];
        [userDefaults synchronize];
    }
    
    BOOL startedRegister = [self registerForAPNsToken];
    
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:[NSString stringWithFormat:@"startedRegister: %d", startedRegister]];
    
    [self.osNotificationSettings onNotificationPromptResponse:notificationTypes];
    
    if (mSubscriptionStatus == -2)
        return;
    
    if (!self.currentSubscriptionState.userId && !startedRegister)
        [OneSignal registerUser];
    else if (self.currentSubscriptionState.pushToken)
        [self sendNotificationTypesUpdate];
    
    if ([self getUsableDeviceToken])
        [self fireIdsAvailableCallback];
}

+ (void)didRegisterForRemoteNotifications:(UIApplication*)app deviceToken:(NSData*)inDeviceToken {
    if ([OneSignal shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    let trimmedDeviceToken = [[inDeviceToken description] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
    let parsedDeviceToken = [[trimmedDeviceToken componentsSeparatedByString:@" "] componentsJoinedByString:@""];
    
    
    [OneSignal onesignal_Log:ONE_S_LL_INFO message: [NSString stringWithFormat:@"Device Registered with Apple: %@", parsedDeviceToken]];
    
    waitingForApnsResponse = false;
    
    if (!app_id)
        return;
    
    [OneSignal updateDeviceToken:parsedDeviceToken onSuccess:^(NSDictionary* results) {
        [OneSignal onesignal_Log:ONE_S_LL_INFO message:[NSString stringWithFormat: @"Device Registered with OneSignal: %@", self.currentSubscriptionState.userId]];
    } onFailure:^(NSError* error) {
        [OneSignal onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat: @"Error in OneSignal Registration: %@", error]];
    }];
}
    
+ (BOOL)remoteSilentNotification:(UIApplication*)application UserInfo:(NSDictionary*)userInfo completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    var startedBackgroundJob = false;
    
    NSDictionary* richData = nil;
    
    // TODO: Look into why the userInfo payload would be different here for displaying vs opening....
    // Check for buttons or attachments pre-2.4.0 version
    if ((userInfo[@"os_data"][@"buttons"] && [userInfo[@"os_data"][@"buttons"] isKindOfClass:[NSDictionary class]]) || userInfo[@"at"] || userInfo[@"o"])
        richData = userInfo;
    
    // Generate local notification for action button and/or attachments.
    if (richData) {
        let osPayload = [OSNotificationPayload parseWithApns:userInfo];
        
        if ([OneSignalHelper isIOSVersionGreaterOrEqual:10]) {
            startedBackgroundJob = true;
            [OneSignalHelper addNotificationRequest:osPayload completionHandler:completionHandler];
        }
        else {
            let notification = [OneSignalHelper prepareUILocalNotification:osPayload];
            [[UIApplication sharedApplication] scheduleLocalNotification:notification];
        }
    }
    // Method was called due to a tap on a notification - Fire open notification
    else if (application.applicationState != UIApplicationStateBackground) {
        [OneSignalHelper lastMessageReceived:userInfo];
        
        if (application.applicationState == UIApplicationStateActive)
            [OneSignalHelper handleNotificationReceived:OSNotificationDisplayTypeNotification];
        
        if (![OneSignalHelper isRemoteSilentNotification:userInfo])
            [OneSignal notificationReceived:userInfo isActive:NO wasOpened:YES];
        
        return startedBackgroundJob;
    }
    // content-available notification received in the background - Fire handleNotificationReceived block in app
    else {
        [OneSignalHelper lastMessageReceived:userInfo];
        if ([OneSignalHelper isRemoteSilentNotification:userInfo])
            [OneSignalHelper handleNotificationReceived:OSNotificationDisplayTypeNone];
        else
            [OneSignalHelper handleNotificationReceived:OSNotificationDisplayTypeNotification];
    }
    
    return startedBackgroundJob;
}

// iOS 8-9 - Entry point when OneSignal action button notification is displayed or opened.
+ (void)processLocalActionBasedNotification:(UILocalNotification*) notification identifier:(NSString*)identifier {
    if ([OneSignal shouldLogMissingPrivacyConsentErrorWithMethodName:nil])
        return;
    
    if (!notification.userInfo)
        return;

    let userInfo = [OneSignalHelper formatApsPayloadIntoStandard:notification.userInfo identifier:identifier];
    
    if (!userInfo)
        return;
    
    let isActive = [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive;
    [OneSignal notificationReceived:userInfo isActive:isActive wasOpened:YES];
    
    // Notification Tapped or notification Action Tapped
    if (!isActive)
        [self handleNotificationOpened:userInfo
                              isActive:isActive
                            actionType:OSNotificationActionTypeActionTaken
                           displayType:OSNotificationDisplayTypeNotification];
}

+ (void)syncHashedEmail:(NSString *)email {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"syncHashedEmail:"])
        return;
    
    if (!email) {
        [self onesignal_Log:ONE_S_LL_WARN message:@"OneSignal syncHashedEmail: The provided email is nil"];
        return;
    }
    
    let trimmedEmail = [email stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    if (![OneSignalHelper isValidEmail:trimmedEmail]) {
        [self onesignal_Log:ONE_S_LL_WARN message:@"OneSignal syncHashedEmail: The provided email is invalid"];
        return;
    }
    
    if (!self.currentSubscriptionState.userId) {
        emailToSet = email;
        return;
    }
    
    [OneSignalClient.sharedClient executeRequest:[OSRequestSyncHashedEmail withUserId:self.currentSubscriptionState.userId appId:self.app_id email:trimmedEmail networkType:[OneSignalHelper getNetType]] onSuccess:nil onFailure:nil];
}

// Called from the app's Notification Service Extension
+ (UNMutableNotificationContent*)didReceiveNotificationExtensionRequest:(UNNotificationRequest*)request withMutableNotificationContent:(UNMutableNotificationContent*)replacementContent {
    
    return [OneSignalNotificationServiceExtensionHandler
            didReceiveNotificationExtensionRequest:request
            withMutableNotificationContent:replacementContent];
}


// Called from the app's Notification Service Extension
+ (UNMutableNotificationContent*)serviceExtensionTimeWillExpireRequest:(UNNotificationRequest*)request withMutableNotificationContent:(UNMutableNotificationContent*)replacementContent {
    return [OneSignalNotificationServiceExtensionHandler
            serviceExtensionTimeWillExpireRequest:request
            withMutableNotificationContent:replacementContent];
}

#pragma mark Email

+ (void)callFailureBlockOnMainThread:(OSFailureBlock)failureBlock withError:(NSError *)error {
    if (failureBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            failureBlock(error);
        });
    }
}

+ (void)callSuccessBlockOnMainThread:(OSEmailSuccessBlock)successBlock {
    if (successBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            successBlock();
        });
    }
}

+ (void)setEmail:(NSString * _Nonnull)email withEmailAuthHashToken:(NSString * _Nullable)hashToken withSuccess:(OSEmailSuccessBlock _Nullable)successBlock withFailure:(OSEmailFailureBlock _Nullable)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"setEmail:withEmailAuthHashToken:withSuccess:withFailure:"])
        return;
    
    //some clients/wrappers may send NSNull instead of nil as the auth token
    NSString *emailAuthToken = hashToken;
    if (hashToken == (id)[NSNull null])
        emailAuthToken = nil;
    
    //checks to ensure it is a valid email
    if (![OneSignalHelper isValidEmail:email]) {
        [self onesignal_Log:ONE_S_LL_WARN message:[NSString stringWithFormat:@"Invalid email (%@) passed to setEmail", email]];
        if (failureBlock)
            failureBlock([NSError errorWithDomain:@"com.onesignal" code:0 userInfo:@{@"error" : @"Email is invalid"}]);
        return;
    }
    
    //checks to make sure that if email_auth is required, the user has passed in a hash token
    if (self.currentEmailSubscriptionState.requiresEmailAuth && (!emailAuthToken || emailAuthToken.length == 0)) {
        if (failureBlock)
            failureBlock([NSError errorWithDomain:@"com.onesignal.email" code:0 userInfo:@{@"error" : @"Email authentication (auth token) is set to REQUIRED for this application. Please provide an auth token from your backend server or change the setting in the OneSignal dashboard."}]);
        return;
    }
    
    // if both the email address & hash token are the same, there's no need to make a network call here.
    if ([self.currentEmailSubscriptionState.emailAddress isEqualToString:email] && ([self.currentEmailSubscriptionState.emailAuthCode isEqualToString:emailAuthToken] || (self.currentEmailSubscriptionState.emailAuthCode == nil && emailAuthToken == nil))) {
        [self onesignal_Log:ONE_S_LL_VERBOSE message:@"Email already exists, there is no need to call setEmail again"];
        if (successBlock)
            successBlock();
        return;
    }
    
    /*
       if the iOS params (with the require_email_auth setting) has not been downloaded yet, we should delay the request
       however, if this method was called with an email auth code passed in, then there is no need to check this setting
       and we do not need to delay the request
    */
    
    if (!self.currentSubscriptionState.userId || (downloadedParameters == false && emailAuthToken != nil)) {
        [self onesignal_Log:ONE_S_LL_VERBOSE message:@"iOS Parameters for this application has not yet been downloaded. Delaying call to setEmail: until the parameters have been downloaded."];
        delayedEmailParameters = [OneSignalSetEmailParameters withEmail:email withAuthToken:emailAuthToken withSuccess:successBlock withFailure:failureBlock];
        return;
    }
    
    // if the user already has a onesignal email player_id, then we should call update the device token
    // otherwise we should call Create Device
    // since developers may be making UI changes when this call finishes, we will call callbacks on the main thread.
    
    if (self.currentEmailSubscriptionState.emailUserId) {
        [OneSignalClient.sharedClient executeRequest:[OSRequestUpdateDeviceToken withUserId:self.currentEmailSubscriptionState.emailUserId appId:self.app_id deviceToken:email notificationTypes:nil withParentId:nil emailAuthToken:emailAuthToken email:nil] onSuccess:^(NSDictionary *result) {
            [self callSuccessBlockOnMainThread:successBlock];
        } onFailure:^(NSError *error) {
            [self callFailureBlockOnMainThread:failureBlock withError:error];
        }];
    } else {
        [OneSignalClient.sharedClient executeRequest:[OSRequestCreateDevice withAppId:self.app_id withDeviceType:@11 withEmail:email withPlayerId:self.currentSubscriptionState.userId withEmailAuthHash:emailAuthToken] onSuccess:^(NSDictionary *result) {
            
            let emailPlayerId = (NSString *)result[@"id"];
            
            if (emailPlayerId) {
                self.currentEmailSubscriptionState.emailAddress = email;
                self.currentEmailSubscriptionState.emailAuthCode = emailAuthToken;
                self.currentEmailSubscriptionState.emailUserId = emailPlayerId;
                
                //call persistAsFrom in order to save the emailAuthToken & playerId to NSUserDefaults
                [self.currentEmailSubscriptionState persist];
                
                [OneSignalClient.sharedClient executeRequest:[OSRequestUpdateDeviceToken withUserId:self.currentSubscriptionState.userId appId:self.app_id deviceToken:nil notificationTypes:@([self getNotificationTypes]) withParentId:self.currentEmailSubscriptionState.emailUserId emailAuthToken:hashToken email:email] onSuccess:^(NSDictionary *result) {
                    [self callSuccessBlockOnMainThread:successBlock];
                } onFailure:^(NSError *error) {
                    [self callFailureBlockOnMainThread:failureBlock withError:error];
                }];
            } else {
                [self onesignal_Log:ONE_S_LL_ERROR message:@"Missing OneSignal Email Player ID"];
            }
        } onFailure:^(NSError *error) {
            [self callFailureBlockOnMainThread:failureBlock withError:error];
        }];
    }
}

+ (void)setEmail:(NSString * _Nonnull)email withSuccess:(OSEmailSuccessBlock _Nullable)successBlock withFailure:(OSEmailFailureBlock _Nullable)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"setEmail:withSuccess:withFailure:"])
        return;
    
    [self setEmail:email withEmailAuthHashToken:nil withSuccess:successBlock withFailure:failureBlock];
}

+ (void)logoutEmailWithSuccess:(OSEmailSuccessBlock _Nullable)successBlock withFailure:(OSEmailFailureBlock _Nullable)failureBlock {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"logoutEmailWithSuccess:withFailure:"])
        return;
    
    if (!self.currentEmailSubscriptionState.emailUserId) {
        [OneSignal onesignal_Log:ONE_S_LL_ERROR message:@"Email Player ID does not exist, cannot logout"];
        
        if (failureBlock)
            failureBlock([NSError errorWithDomain:@"com.onesignal" code:0 userInfo:@{@"error" : @"Attempted to log out of the user's email with OneSignal. The user does not currently have an email player ID and is not logged in, so it is not possible to log out of the email for this device"}]);
        return;
    }
    
    
    [OneSignalClient.sharedClient executeRequest:[OSRequestLogoutEmail withAppId: self.app_id emailPlayerId:self.currentEmailSubscriptionState.emailUserId devicePlayerId:self.currentSubscriptionState.userId emailAuthHash:self.currentEmailSubscriptionState.emailAuthCode] onSuccess:^(NSDictionary *result) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:EMAIL_USERID];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        self.currentEmailSubscriptionState.emailAddress = nil;
        self.currentEmailSubscriptionState.emailAuthCode = nil;
        self.currentEmailSubscriptionState.emailUserId = nil;
        
        //call persistAsFrom in order to save the hashToken & playerId to NSUserDefaults
        [self.currentEmailSubscriptionState persist];
        
        [self callSuccessBlockOnMainThread:successBlock];
    } onFailure:^(NSError *error) {
        [self callFailureBlockOnMainThread:failureBlock withError:error];
    }];
}

+ (void)setEmail:(NSString * _Nonnull)email {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"setEmail:"])
        return;
    
    [self setEmail:email withSuccess:nil withFailure:nil];
}

+ (void)logoutEmail {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"logoutEmail"])
        return;
    
    [self logoutEmailWithSuccess:nil withFailure:nil];
}

+ (void)setEmail:(NSString * _Nonnull)email withEmailAuthHashToken:(NSString * _Nullable)hashToken {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"setEmail:withEmailAuthHashToken:"])
        return;
    
    [self setEmail:email withEmailAuthHashToken:hashToken withSuccess:nil withFailure:nil];
}

+ (void)emailChangedWithNewEmailPlayerId:(NSString * _Nullable)emailPlayerId {
    //make sure that the email player ID has changed otherwise there's no point in this request
    if ([self.currentEmailSubscriptionState.emailUserId isEqualToString:emailPlayerId])
        return;
    
    self.currentEmailSubscriptionState.emailUserId = emailPlayerId;
    
    [self.currentEmailSubscriptionState persist];
    
    let request = [OSRequestUpdateDeviceToken withUserId:self.currentSubscriptionState.userId
                                                   appId:self.app_id
                                                   deviceToken:nil
                                                   notificationTypes: @([self getNotificationTypes])
                                                   withParentId:emailPlayerId
                                                   emailAuthToken:self.currentEmailSubscriptionState.emailAuthCode
                                                   email:self.currentEmailSubscriptionState.emailAddress];
    
    [OneSignalClient.sharedClient executeRequest:request onSuccess:nil onFailure:^(NSError *error) {
        [self onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat:@"Encountered an error updating this user's email player record: %@", error.description]];
    }];
}

+ (void)setExternalUserId:(NSString * _Nonnull)externalId {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"setExternalUserId:"])
        return;
    
    if ([self.existingExternalUserId isEqualToString:externalId])
        return;
    
    if (!performedOnSessionRequest) {
        // will be sent as part of the registration/on_session request
        pendingExternalUserId = externalId;
        return;
    } else if (!self.currentSubscriptionState.userId || !self.app_id) {
        [self onesignal_Log:ONE_S_LL_WARN message:[NSString stringWithFormat:@"Attempted to set external-userID while %@ is not set", self.app_id == nil ? @"app ID" : @"OneSignal user ID"]];
        return;
    }
    
    let requests = [NSMutableDictionary new];
    requests[@"push"] = [OSRequestUpdateExternalUserId withUserId:externalId withOneSignalUserId:self.currentSubscriptionState.userId appId:self.app_id];
    
    if (self.currentEmailSubscriptionState.emailUserId && (self.currentEmailSubscriptionState.requiresEmailAuth == false || self.currentEmailSubscriptionState.emailAuthCode))
        requests[@"email"] = [OSRequestUpdateExternalUserId withUserId:externalId withOneSignalUserId:self.currentEmailSubscriptionState.emailUserId appId:self.app_id];
    
    [OneSignalClient.sharedClient executeSimultaneousRequests:requests withSuccess:^(NSDictionary<NSString *,NSDictionary *> *results) {
        // the success/fail callbacks always execute on the main thread
        [self successfullySentExternalUserId:externalId];
    } onFailure:^(NSDictionary<NSString *,NSError *> *errors) {
        // if either request fails, this block is executed
        NSError *error = errors[@"push"] ?: errors[@"email"];
        [self onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat:@"Encountered an error while attempting to set external ID: %@", error.description]];
    }];
}

+ (NSString *)existingExternalUserId {
    return [NSUserDefaults.standardUserDefaults stringForKey:EXTERNAL_USER_ID] ?: @"";
}

+ (void)successfullySentExternalUserId:(NSString *)externalId {
    [NSUserDefaults.standardUserDefaults setObject:externalId forKey:EXTERNAL_USER_ID];
    [NSUserDefaults.standardUserDefaults synchronize];
}

+ (void)removeExternalUserId {
    
    // return if the user has not granted privacy permissions
    if ([self shouldLogMissingPrivacyConsentErrorWithMethodName:@"removeExternalUserId"])
        return;
    
    [self setExternalUserId:@""];
}


@end

// Swizzles UIApplication class to swizzling the following:
//   - UIApplication
//      - setDelegate:
//        - Used to swizzle all UIApplicationDelegate selectors on the passed in class.
//        - Almost always this is the AppDelegate class but since UIApplicationDelegate is an "interface" this could be any class.
//   - UNUserNotificationCenter
//     - setDelegate:
//        - For iOS 10 only, swizzle all UNUserNotificationCenterDelegate selectors on the passed in class.
//         -  This may or may not be set so we set our own now in registerAsUNNotificationCenterDelegate to an empty class.
//
//  Note1: Do NOT move this category to it's own file. This is required so when the app developer calls OneSignal.initWithLaunchOptions this load+
//            will fire along with it. This is due to how iOS loads .m files into memory instead of classes.
//  Note2: Do NOT directly add swizzled selectors to this category as if this class is loaded into the runtime twice unexpected results will occur.
//            The oneSignalLoadedTagSelector: selector is used a flag to prevent double swizzling if this library is loaded twice.
@implementation UIApplication (OneSignal)
#define SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(v)     ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedDescending)
+ (void)load {
    [OneSignal onesignal_Log:ONE_S_LL_VERBOSE message:@"UIApplication(OneSignal) LOADED!"];
    
    // Prevent Xcode storyboard rendering process from crashing with custom IBDesignable Views
    // https://github.com/OneSignal/OneSignal-iOS-SDK/issues/160
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if ([[processInfo processName] isEqualToString:@"IBDesignablesAgentCocoaTouch"] || [[processInfo processName] isEqualToString:@"IBDesignablesAgent-iOS"])
        return;
    
    if (SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(@"7.0"))
        return;

    // Double loading of class detection.
    BOOL existing = injectSelector([OneSignalAppDelegate class], @selector(oneSignalLoadedTagSelector:), self, @selector(oneSignalLoadedTagSelector:));
    if (existing) {
        [OneSignal onesignal_Log:ONE_S_LL_WARN message:@"Already swizzled UIApplication.setDelegate. Make sure the OneSignal library wasn't loaded into the runtime twice!"];
        return;
    }
    
    
    // Swizzle - UIApplication delegate
    injectToProperClass(@selector(setOneSignalDelegate:), @selector(setDelegate:), @[], [OneSignalAppDelegate class], [UIApplication class]);
    
    injectToProperClass(@selector(onesignalSetApplicationIconBadgeNumber:), @selector(setApplicationIconBadgeNumber:), @[], [OneSignalAppDelegate class], [UIApplication class]);
    
    [self setupUNUserNotificationCenterDelegate];
}

/*
    In order for the badge count to be consistent even in situations where the developer manually sets the badge number,
    We swizzle the 'setApplicationIconBadgeNumber()' to intercept these calls so we always know the latest count
*/
- (void)onesignalSetApplicationIconBadgeNumber:(NSInteger)badge {
    [OneSignalExtensionBadgeHandler updateCachedBadgeValue:badge];
    
    [self onesignalSetApplicationIconBadgeNumber:badge];
}

+(void)setupUNUserNotificationCenterDelegate {
    // Swizzle - UNUserNotificationCenter delegate - iOS 10+
    if (!NSClassFromString(@"UNUserNotificationCenter"))
        return;

    [OneSignalUNUserNotificationCenter swizzleSelectors];

    // Set our own delegate if one hasn't been set already from something else.
    [OneSignalHelper registerAsUNNotificationCenterDelegate];
}

@end


#pragma clang diagnostic pop
#pragma clang diagnostic pop
