// AFOAuth2Client.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFJSONRequestOperation.h"

#import "AFOAuth2Client.h"

NSString * const kAFOAuthCodeGrantType = @"authorization_code";
NSString * const kAFOAuthClientCredentialsGrantType = @"client_credentials";
NSString * const kAFOAuthPasswordCredentialsGrantType = @"password";
NSString * const kAFOAuthRefreshGrantType = @"refresh_token";
NSString * const AFOAuth2ClientError = @"com.alamofire.networking.oauth2.error";

#ifdef _SECURITY_SECITEM_H_
NSString * const kAFOAuth2CredentialServiceName = @"AFOAuthCredentialService";

static NSMutableDictionary * AFKeychainQueryDictionaryWithIdentifier(NSString *identifier) {
    NSMutableDictionary *queryDictionary = [NSMutableDictionary dictionaryWithObjectsAndKeys:(__bridge id)kSecClassGenericPassword, kSecClass, kAFOAuth2CredentialServiceName, kSecAttrService, nil];
    [queryDictionary setValue:identifier forKey:(__bridge id)kSecAttrAccount];

    return queryDictionary;
}
#endif

// OAuth 2 Error Response
// See http://tools.ietf.org/html/rfc6749#section-5.2
static NSError * AFOAuth2ErrorFromResponseObjectAndError(NSDictionary *responseObject, NSError * underlyingError) {
    id value = [responseObject valueForKey:@"error"];
    NSString *localizedDescription = nil;
    AFOAuth2ClientErrorCode code = AFOAuth2OtherError;

    if (value) {
        if ([value isEqualToString:@"invalid_request"]) {
            localizedDescription = NSLocalizedStringFromTable(@"The request is missing a required parameter, includes an unsupported parameter value (other than grant type), repeats a parameter, includes multiple credentials, utilizes more than one mechanism for authenticating the client, or is otherwise malformed.", @"AFOAuth2Client", nil);
            code = AFOAuth2InvalidRequest;
        } else if ([value isEqualToString:@"invalid_client"]) {
            localizedDescription = NSLocalizedStringFromTable(@"Client authentication failed (e.g., unknown client, no client authentication included, or unsupported authentication method). The authorization server MAY return an HTTP 401 (Unauthorized) status code to indicate which HTTP authentication schemes are supported. If the client attempted to authenticate via the \"Authorization\" request header field, the authorization server MUST respond with an HTTP 401 (Unauthorized) status code and include the \"WWW-Authenticate\" response header field matching the authentication scheme used by the client.", @"AFOAuth2Client", nil);
            code = AFOAuth2InvalidClient;
        } else if ([value isEqualToString:@"invalid_grant"]) {
            localizedDescription = NSLocalizedStringFromTable(@"The provided authorization grant (e.g., authorization code, resource owner credentials) or refresh token is invalid, expired, revoked, does not match the redirection URI used in the authorization request, or was issued to another client.", @"AFOAuth2Client", nil);
            code = AFOAuth2InvalidGrant;
        } else if ([value isEqualToString:@"unauthorized_client"]) {
            localizedDescription = NSLocalizedStringFromTable(@"The authenticated client is not authorized to use this authorization grant type.", @"AFOAuth2Client", nil);
            code = AFOAuth2UnauthorizedClient;
        } else if ([value isEqualToString:@"unsupported_grant_type"]) {
            localizedDescription = NSLocalizedStringFromTable(@"The authorization grant type is not supported by the authorization server.", @"AFOAuth2Client", nil);
            code = AFOAuth2UnsupportedGrantType;
        } else if ([value isEqualToString:@"invalid_scope"]) {
            localizedDescription = NSLocalizedStringFromTable(@"The requested scope is invalid, unknown, malformed, or exceeds the scope granted by the resource owner.", @"AFOAuth2Client", nil);
            code = AFOAuth2InvalidScope;
        }

        if (localizedDescription) {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                      localizedDescription, NSLocalizedDescriptionKey,
                                      underlyingError, NSUnderlyingErrorKey,
                                      nil
                                      ];
            return [NSError errorWithDomain:AFOAuth2ClientError code:code userInfo:userInfo];
        }
    }

    return nil;
}

#pragma mark -

@interface AFOAuth2Client ()
@property (readwrite, nonatomic) NSString *serviceProviderIdentifier;
@property (readwrite, nonatomic) NSString *clientID;
@property (readwrite, nonatomic) NSString *secret;
@property (readonly, nonatomic)  BOOL basicAuth;
@end

@implementation AFOAuth2Client

+ (instancetype)clientWithBaseURL:(NSURL *)url
                         clientID:(NSString *)clientID
                           secret:(NSString *)secret
{
    return [[self alloc] initWithBaseURL:url clientID:clientID secret:secret];
}

-(id)initWithBaseURL:(NSURL *)url
            clientID:(NSString *)clientID
              secret:(NSString *)secret
{
    return [self initWithBaseURL:url clientID:clientID secret:secret withBasicAuth:YES];
}

- (id)initWithBaseURL:(NSURL *)url
             clientID:(NSString *)clientID
               secret:(NSString *)secret
        withBasicAuth:(BOOL)basicAuth
{
    NSParameterAssert(clientID);

    self = [super initWithBaseURL:url];
    if (!self) {
        return nil;
    }

    self.serviceProviderIdentifier = [self.baseURL host];
    self.clientID = clientID;
    self.secret = secret;
    _basicAuth = basicAuth;
    if (self.basicAuth)
    {
        [self setAuthorizationHeaderWithUsername:clientID password:secret];
    }

    [self registerHTTPOperationClass:[AFJSONRequestOperation class]];

    return self;
}

#pragma mark -

- (void)setAuthorizationHeaderWithToken:(NSString *)token {
    // Use the "Bearer" type as an arbitrary default
    [self setAuthorizationHeaderWithToken:token ofType:@"Bearer"];
}

- (void)setAuthorizationHeaderWithCredential:(AFOAuthCredential *)credential {
    [self setAuthorizationHeaderWithToken:credential.accessToken ofType:credential.tokenType];
}

- (void)setAuthorizationHeaderWithToken:(NSString *)token
                                 ofType:(NSString *)type
{
    // See http://tools.ietf.org/html/rfc6749#section-7.1
    if ([[type lowercaseString] isEqualToString:@"bearer"]) {
        [self setDefaultHeader:@"Authorization" value:[NSString stringWithFormat:@"Bearer %@", token]];
    }
}

#pragma mark -

- (void)authenticateUsingOAuthWithPath:(NSString *)path
                              username:(NSString *)username
                              password:(NSString *)password
                                 scope:(NSString *)scope
                               success:(void (^)(AFOAuthCredential *credential))success
                               failure:(void (^)(NSError *error))failure
{
    NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionary];
    [mutableParameters setObject:kAFOAuthPasswordCredentialsGrantType forKey:@"grant_type"];
    [mutableParameters setValue:username forKey:@"username"];
    [mutableParameters setValue:password forKey:@"password"];
    [mutableParameters setValue:scope forKey:@"scope"];
    NSDictionary *parameters = [NSDictionary dictionaryWithDictionary:mutableParameters];

    [self authenticateUsingOAuthWithPath:path parameters:parameters success:success failure:failure];
}

- (void)authenticateUsingOAuthWithPath:(NSString *)path
                                 scope:(NSString *)scope
                               success:(void (^)(AFOAuthCredential *credential))success
                               failure:(void (^)(NSError *error))failure
{
    NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionary];
    [mutableParameters setObject:kAFOAuthClientCredentialsGrantType forKey:@"grant_type"];
    [mutableParameters setValue:scope forKey:@"scope"];
    NSDictionary *parameters = [NSDictionary dictionaryWithDictionary:mutableParameters];

    [self authenticateUsingOAuthWithPath:path parameters:parameters success:success failure:failure];
}

- (void)authenticateUsingOAuthWithPath:(NSString *)path
                          refreshToken:(NSString *)refreshToken
                               success:(void (^)(AFOAuthCredential *credential))success
                               failure:(void (^)(NSError *error))failure
{
    NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionary];
    [mutableParameters setObject:kAFOAuthRefreshGrantType forKey:@"grant_type"];
    [mutableParameters setValue:refreshToken forKey:@"refresh_token"];
    NSDictionary *parameters = [NSDictionary dictionaryWithDictionary:mutableParameters];

    [self authenticateUsingOAuthWithPath:path parameters:parameters success:success failure:failure];
}

- (void)authenticateUsingOAuthWithPath:(NSString *)path
                                  code:(NSString *)code
                           redirectURI:(NSString *)uri
                               success:(void (^)(AFOAuthCredential *credential))success
                               failure:(void (^)(NSError *error))failure
{
    NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionary];
    [mutableParameters setObject:kAFOAuthCodeGrantType forKey:@"grant_type"];
    [mutableParameters setValue:code forKey:@"code"];
    [mutableParameters setValue:uri forKey:@"redirect_uri"];
    NSDictionary *parameters = [NSDictionary dictionaryWithDictionary:mutableParameters];

    [self authenticateUsingOAuthWithPath:path parameters:parameters success:success failure:failure];
}

- (void)authenticateUsingOAuthWithPath:(NSString *)path
                            parameters:(NSDictionary *)parameters
                               success:(void (^)(AFOAuthCredential *credential))success
                               failure:(void (^)(NSError *error))failure
{
    NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    if (!self.basicAuth)
    {
        [mutableParameters setObject:self.clientID forKey:@"client_id"];
        [mutableParameters setValue:self.secret forKey:@"client_secret"];
    }
    parameters = [NSDictionary dictionaryWithDictionary:mutableParameters];

    NSMutableURLRequest *mutableRequest = [self requestWithMethod:@"POST" path:path parameters:parameters];
    [mutableRequest setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    AFHTTPRequestOperation *requestOperation = [self HTTPRequestOperationWithRequest:mutableRequest success:^(AFHTTPRequestOperation *operation, id responseObject) {
        if (responseObject == nil || [responseObject valueForKey:@"error"]) {
            if (failure) {
                NSError *error = AFOAuth2ErrorFromResponseObjectAndError(responseObject, nil);
                failure(error);
            }
            return;
        }

        NSString *refreshToken = [responseObject valueForKey:@"refresh_token"];
        if (refreshToken == nil || [refreshToken isEqual:[NSNull null]]) {
            refreshToken = [parameters valueForKey:@"refresh_token"];
        }

        NSDate *expireDate = nil;
        id expiresIn = [responseObject valueForKey:@"expires_in"];
        if (expiresIn != nil && ![expiresIn isEqual:[NSNull null]]) {
            expireDate = [NSDate dateWithTimeIntervalSinceNow:[expiresIn doubleValue]];
        }
        
        AFOAuthCredential *credential = [AFOAuthCredential credentialWithOAuthToken:[responseObject valueForKey:@"access_token"] tokenType:[responseObject valueForKey:@"token_type"] expiration:expireDate];

        if (refreshToken)
        {
            [credential setRefreshToken:refreshToken];
        }

        if (success) {
            success(credential);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (self.basicAuth)
        {
            [self setAuthorizationHeaderWithUsername:self.clientID password:self.secret];
        }
        if (failure) {
            NSError * e = AFOAuth2ErrorFromResponseObjectAndError([(AFJSONRequestOperation*)operation responseJSON], error);
            failure(e);
        }
    }];

    [self enqueueHTTPRequestOperation:requestOperation];
}

@end

#pragma mark -

@interface AFOAuthCredential ()
@property (readwrite, nonatomic) NSString *accessToken;
@property (readwrite, nonatomic) NSString *tokenType;
@property (readwrite, nonatomic) NSString *refreshToken;
@property (readwrite, nonatomic) NSDate *expiration;
@end

@implementation AFOAuthCredential
@synthesize accessToken = _accessToken;
@synthesize tokenType = _tokenType;
@synthesize refreshToken = _refreshToken;
@synthesize expiration = _expiration;
@dynamic expired;

#pragma mark -

+ (instancetype)credentialWithOAuthToken:(NSString *)token
                               tokenType:(NSString *)type
                              expiration:(NSDate *)expiration
{
    return [[self alloc] initWithOAuthToken:token tokenType:type expiration:expiration];
}

- (id)initWithOAuthToken:(NSString *)token
               tokenType:(NSString *)type
              expiration:(NSDate *)expiration
{
    self = [super init];
    if (!self) {
        return nil;
    }

    NSParameterAssert(expiration);
    
    self.accessToken = token;
    self.tokenType = type;
    self.expiration = expiration;

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ accessToken:\"%@\" tokenType:\"%@\" refreshToken:\"%@\" expiration:\"%@\">", [self class], self.accessToken, self.tokenType, self.refreshToken, self.expiration];
}

- (BOOL)isExpired {
    return [self.expiration compare:[NSDate date]] == NSOrderedAscending;
}

#pragma mark Keychain

#ifdef _SECURITY_SECITEM_H_

+ (BOOL)storeCredential:(AFOAuthCredential *)credential
         withIdentifier:(NSString *)identifier
{
    id securityAccessibility = nil;
#if (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 43000) || (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 1090)
    securityAccessibility = (__bridge id)kSecAttrAccessibleWhenUnlocked;
#endif
    
    return [[self class] storeCredential:credential withIdentifier:identifier withAccessibility:securityAccessibility];
}

+ (BOOL)storeCredential:(AFOAuthCredential *)credential
         withIdentifier:(NSString *)identifier
      withAccessibility:(id)securityAccessibility
{
    NSMutableDictionary *queryDictionary = AFKeychainQueryDictionaryWithIdentifier(identifier);

    if (!credential) {
        return [self deleteCredentialWithIdentifier:identifier];
    }

    NSMutableDictionary *updateDictionary = [NSMutableDictionary dictionary];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:credential];
    [updateDictionary setObject:data forKey:(__bridge id)kSecValueData];
    if (securityAccessibility) {
        [updateDictionary setObject:securityAccessibility forKey:(__bridge id)kSecAttrAccessible];
    }

    OSStatus status;
    BOOL exists = ([self retrieveCredentialWithIdentifier:identifier] != nil);

    if (exists) {
        status = SecItemUpdate((__bridge CFDictionaryRef)queryDictionary, (__bridge CFDictionaryRef)updateDictionary);
    } else {
        [queryDictionary addEntriesFromDictionary:updateDictionary];
        status = SecItemAdd((__bridge CFDictionaryRef)queryDictionary, NULL);
    }

    if (status != errSecSuccess) {
        NSLog(@"Unable to %@ credential with identifier \"%@\" (Error %li)", exists ? @"update" : @"add", identifier, (long int)status);
    }

    return (status == errSecSuccess);
}

+ (BOOL)deleteCredentialWithIdentifier:(NSString *)identifier {
    NSMutableDictionary *queryDictionary = AFKeychainQueryDictionaryWithIdentifier(identifier);

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)queryDictionary);

    if (status != errSecSuccess) {
        NSLog(@"Unable to delete credential with identifier \"%@\" (Error %li)", identifier, (long int)status);
    }

    return (status == errSecSuccess);
}

+ (AFOAuthCredential *)retrieveCredentialWithIdentifier:(NSString *)identifier {
    NSMutableDictionary *queryDictionary = AFKeychainQueryDictionaryWithIdentifier(identifier);
    [queryDictionary setObject:(__bridge id)kCFBooleanTrue forKey:(__bridge id)kSecReturnData];
    [queryDictionary setObject:(__bridge id)kSecMatchLimitOne forKey:(__bridge id)kSecMatchLimit];

    CFDataRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)queryDictionary, (CFTypeRef *)&result);

    if (status != errSecSuccess) {
        NSLog(@"Unable to fetch credential with identifier \"%@\" (Error %li)", identifier, (long int)status);
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)result;
    AFOAuthCredential *credential = [NSKeyedUnarchiver unarchiveObjectWithData:data];

    return credential;
}

#endif

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)decoder {
    self = [super init];
    self.accessToken = [decoder decodeObjectForKey:@"accessToken"];
    self.tokenType = [decoder decodeObjectForKey:@"tokenType"];
    self.refreshToken = [decoder decodeObjectForKey:@"refreshToken"];
    self.expiration = [decoder decodeObjectForKey:@"expiration"];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder {
    [encoder encodeObject:self.accessToken forKey:@"accessToken"];
    [encoder encodeObject:self.tokenType forKey:@"tokenType"];
    [encoder encodeObject:self.refreshToken forKey:@"refreshToken"];
    [encoder encodeObject:self.expiration forKey:@"expiration"];
}

@end
