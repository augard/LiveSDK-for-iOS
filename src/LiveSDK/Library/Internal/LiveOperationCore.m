//
//  LiveOperationCore.m
//  Live SDK for iOS
//
//  Copyright (c) 2011 Microsoft Corp. All rights reserved.
//

#import "LiveApiHelper.h"
#import "LiveAuthHelper.h"
#import "LiveConnectClientCore.h"
#import "LiveConnectionHelper.h"
#import "LiveConstants.h"
#import "LiveOperationCore.h"
#import "StringHelper.h"
#import "UrlHelper.h"

@class LiveConnectClientCore;

@implementation LiveOperationCore

@synthesize method = _method,
              path = _path, 
       requestBody = _requestBody,
          delegate = _delegate,
         userState = _userState,
        liveClient = _liveClient, 
       inputStream = _inputStream,
      streamReader,
           request,
   publicOperation,
         rawResult, 
            result,
        connection,
      httpResponse,
      responseData,
         completed,
         httpError;
@synthesize retry = _retry;

- (id) initWithMethod:(NSString *)method
                 path:(NSString *)path
          requestBody:(NSData *)requestBody
             delegate:(id)delegate
            userState:(id)userState
           liveClient:(LiveConnectClientCore *)liveClient
{
    self = [super init];
    if (self) 
    {
        _method = [method copy];
        _path = [path copy];
        _requestBody = [requestBody retain];
        _delegate = delegate;
        _userState = [userState retain]; 
        _liveClient = [liveClient retain];
        httpError = nil;
        completed = NO;
    }
    
    return self;
}

- (id) initWithMethod:(NSString *)method
                 path:(NSString *)path
          inputStream:(NSInputStream *)inputStream
             delegate:(id)delegate
            userState:(id)userState
           liveClient:(LiveConnectClientCore *)liveClient
{
    self = [super init];
    if (self) 
    {
        _method = [method copy];
        _path = [path copy];
        _inputStream = [inputStream retain];
        _delegate = delegate;
        _userState = [userState retain]; 
        _liveClient = [liveClient retain];
        completed = NO;
    }
    
    return self;
}

- (void)dealloc 
{
    _delegate = nil;
    
    [_method release];
    _method = nil;
    
    [_path release];
    _path = nil;
    
    [_requestBody release];
    _requestBody = nil;
    
    [_userState release];
    _userState = nil;

    [_liveClient release];
    _liveClient = nil;
    
    [_inputStream close];
    [_inputStream release];
    _inputStream = nil;
    
    [streamReader release];
    streamReader = nil;
    
    [request release];
    request = nil;
    
    [rawResult release];
    rawResult = nil;
    
    [result release];
    result = nil;
    
    //[connection close];
    [connection release];
    connection = nil;
    
    [responseData release];
    responseData = nil;
    
    publicOperation = nil;
    
    [httpResponse release];
    httpResponse = nil;
    
    [httpError release];
    httpError = nil;
    
    [super dealloc];
}

- (void) execute 
{
    [_liveClient refreshSessionWithDelegate:self
                                  userState:nil];
}

- (void) authCompleted: (LiveConnectSessionStatus) status
               session: (LiveConnectSession *) session
             userState: (id) userState
{
    [self sendRequest];
}

- (void) cancel
{
    NSError *error = [LiveAuthHelper createAuthError:LIVE_ERROR_CODE_API_CANCELED
                                            errorStr:LIVE_ERROR_CODE_S_REQUEST_CANCELED
                                         description:LIVE_ERROR_DESC_API_CANCELED
                                          innerError:nil];
    [self operationFailed:error];
    
    [self dismissCurrentRequest];
}

- (void) dismissCurrentRequest
{
    [connection cancel]; 
}

- (NSURL *)requestUrl
{
    return [LiveApiHelper buildAPIUrl:self.path
                               params:[NSMutableDictionary dictionaryWithObjectsAndKeys:
                                            @"true", LIVE_API_PARAM_SUPPRESS_RESPONSE_CODES,
                                            @"true", LIVE_API_PARAM_SUPPRESS_REDIRECTS,
                                            nil ]];
}

- (void) setRequestContentType
{
    [request setValue:LIVE_API_HEADER_CONTENTTYPE_JSON 
   forHTTPHeaderField:LIVE_API_HEADER_CONTENTTYPE];
}

- (void) readInputStream
{
    self.streamReader = [[[StreamReader alloc]initWithStream:_inputStream
                                                    delegate:self]
                         autorelease ];
    [self.streamReader start];
}

- (void)streamReadingCompleted:(NSData *)data
{
    self.requestBody = data;
    [self sendRequest];
}

- (void)streamReadingFailed:(NSError *)error
{
    [self operationFailed:error];
}

- (void) sendRequest
{
    if (completed) 
    {
        return;
    }
    
    if (_inputStream != nil && _requestBody == nil)
    {
        // We have a stream to read.
        [self readInputStream];
        return;
    }
    
    self.request = [NSMutableURLRequest requestWithURL:self.requestUrl
                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                       timeoutInterval:HTTP_REQUEST_TIMEOUT_INTERVAL];
    
    [request setHTTPMethod:self.method];
    
    
    if ([LiveAuthHelper isSessionValid:_liveClient.session])
    {
        [request setValue:[NSString stringWithFormat:@"bearer %@", self.liveClient.session.accessToken ]
       forHTTPHeaderField:LIVE_API_HEADER_AUTHORIZATION];
    }
    
    // Set this header for SDK usage tracking purpose.
    [request setValue: [LiveApiHelper getXHTTPLiveLibraryHeaderValue]
   forHTTPHeaderField:LIVE_API_HEADER_X_HTTP_LIVE_LIBRARY];
    
    if (self.requestBody != nil)
    {
        [self setRequestContentType];
        [request setHTTPBody:self.requestBody];
    }
    
    self.connection = [LiveConnectionHelper createConnectionWithRequest:request delegate:self];
    [self.connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [(NSURLConnection *)self.connection start];
}

- (NSMutableData *)responseData
{
    if (responseData == nil) 
    {
        responseData = [[NSMutableData alloc] init];
    }

    return responseData;
}

#pragma mark methods on response handling

- (void) operationFailed:(NSError *)error
{
    if (completed) {
        return;
    }
    [self retain];
    
    completed = YES;
    if ([_delegate respondsToSelector:@selector(liveOperationFailed:operation:)]) 
    {
        [_delegate liveOperationFailed:error operation:publicOperation];
        
        // LiveOperation was returned in the interface return. However, the app may not retain the object
        // In order to keep it alive, we keep LiveOperationCore and LiveOperation in circular reference.
        // After the event raised, we set this property to nil to break the circle, so that they are recycled.
        self.publicOperation = nil;
    }
    [self release];
}

- (void) operationCompleted
{
    if (completed) 
    {
        return;
    }
    [self retain];
    
    NSString *textResponse;
    NSDictionary *response;
    NSError *error = nil;
    
    [LiveApiHelper parseApiResponse:responseData 
                       textResponse:&textResponse 
                           response:&response 
                              error:&error];
    
    if (error == nil) 
    {
        error = self.httpError;
    }
    
    if (error == nil)
    {
        self.rawResult = textResponse;
        self.result = response;
        
        if ([_delegate respondsToSelector:@selector(liveOperationSucceeded:)])
        {
            [_delegate liveOperationSucceeded:self.publicOperation];
            // LiveOperation was returned in the interface return. However, the app may not retain the object
            // In order to keep it alive, we keep LiveOperationCore and LiveOperation in circular reference.
            // After the event raised, we set this property to nil to break the circle, so that they are recycled.
            self.publicOperation = nil;
        }
    }
    else
    {
        [self operationFailed:error];
    }
    
    completed = YES;
    self.responseData = nil;
    [self release];
}

- (void) operationReceivedData:(NSData *)data
{
    [self.responseData appendData:data];
}

#pragma mark NSURLConnection Delegate

- (void)connection:(NSURLConnection *)connection 
didReceiveResponse:(NSURLResponse *)response 
{   
    self.httpResponse = (NSHTTPURLResponse *)response;
    if ((httpResponse.statusCode / 100) != 2) 
    {
        NSString *message = [NSString stringWithFormat:@"HTTP error %zd", (ssize_t)httpResponse.statusCode];
        self.httpError = [LiveApiHelper createAPIError:LIVE_ERROR_CODE_S_REQUEST_FAILED
                                               message:message
                                            innerError:nil];
    }
}

- (void)connection:(NSURLConnection *)connection 
    didReceiveData:(NSData *)data 
{
    [self operationReceivedData:data];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)aRequest redirectResponse:(NSURLResponse *)response
{
    if ([[[aRequest URL] absoluteString] hasSuffix:@"psid=1"])
        return [NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@&AVOverride=1&download", [[aRequest URL] absoluteString]]]
                                cachePolicy:[aRequest cachePolicy] timeoutInterval:[aRequest timeoutInterval]];
    else
        return aRequest;
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse*)cachedResponse 
{
    return nil;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection 
{
    [self retain];
    [self operationCompleted];
    self.connection = nil;
    [self release];
}

- (void)connection:(NSURLConnection *)connection 
  didFailWithError:(NSError *)error 
{
    [self retain];
    
    self.connection = nil;
    
    if (([error code] == 1003 || [error code] == 1001) && _retry == NO) {
        _retry = YES;
        [self sendRequest];
    } else {
        [self operationFailed:error];
    }
    [self release];
}

@end
