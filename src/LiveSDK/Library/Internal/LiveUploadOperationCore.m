//
//  LiveUploadOperationCore.m
//  Live SDK for iOS
//
//  Copyright (c) 2011 Microsoft. All rights reserved.
//

#import "LiveApiHelper.h"
#import "LiveConnectClientCore.h"
#import "LiveOperation.h"
#import "LiveUploadOperationCore.h"
#import "StringHelper.h"
#import "UrlHelper.h"

@implementation LiveUploadOperationCore

- (id) initWithPath:(NSString *)path
           fileName:(NSString *)fileName
               data:(NSData *)data
          overwrite:(LiveUploadOverwriteOption)overwrite
           delegate:(id <LiveUploadOperationDelegate>)delegate
          userState:(id)userState
         liveClient:(LiveConnectClientCore *)liveClient
{
    self = [super initWithMethod:@"PUT" 
                            path:path 
                     requestBody:data 
                        delegate:delegate 
                       userState:userState 
                      liveClient:liveClient];
    if (self)
    {
        _fileName = [fileName copy];
        _overwrite = overwrite;
        
        [self retain];
    }
    
    return self;
}

- (id) initWithPath:(NSString *)path
           fileName:(NSString *)fileName
        inputStream:(NSInputStream *)inputStream
          overwrite:(LiveUploadOverwriteOption)overwrite
           delegate:(id <LiveUploadOperationDelegate>)delegate
          userState:(id)userState
         liveClient:(LiveConnectClientCore *)liveClient
{
    self = [super initWithMethod:@"PUT" 
                            path:path 
                     inputStream:inputStream 
                        delegate:delegate 
                       userState:userState 
                      liveClient:liveClient];
    if (self)
    {
        _fileName = [fileName copy];
        _overwrite = overwrite;
        
        [self retain];
    }
    
    return self;
}

- (void)dealloc
{
    _fileName = nil;
    [_fileName release];
    _queryUploadLocationOp = nil;
    [_queryUploadLocationOp release];
    _uploadPath = nil;
    [_uploadPath release];
    
    [super dealloc];
}

#pragma mark override methods

- (NSURL *)requestUrl
{
    NSString *uploadPath = _uploadPath;
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   @"true", LIVE_API_PARAM_SUPPRESS_RESPONSE_CODES,
                                   nil];
    if (![LiveApiHelper isFilePath:self.path]) 
    {
        NSString *encodedFileNamePath = [_fileName stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        uploadPath = [uploadPath stringByAppendingString:encodedFileNamePath];
    
        NSString *overwrite = @"false";
        switch (_overwrite) 
        {
            case LiveUploadOverwrite:
                overwrite = @"true";
                break;
            case LiveUploadDoNotOverwrite:
                overwrite = @"false";
                break;
            case LiveUploadRename:
                overwrite = @"choosenewname";
                break;
            default:
                break;
        }
        
        [params setObject:overwrite forKey:LIVE_API_PARAM_OVERWRITE];
    }
    
    // Ensure that we carry over the original query path to the upload path
    NSString *query = [UrlHelper getQueryString:self.path];
    NSString *baseUrl = [UrlHelper appendQueryString:query toPath:uploadPath];
    
    return [LiveApiHelper buildAPIUrl:baseUrl
                               params:params];
}

- (void) setRequestContentType
{
    // override the behaviour in LiveOperation.
}

- (void)connection:(NSURLConnection *)connection 
   didSendBodyData:(NSInteger)bytesWritten 
 totalBytesWritten:(NSInteger)totalBytesWritten 
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    LiveOperationProgress *progress = [[[LiveOperationProgress alloc] initWithBytesTransferred:totalBytesWritten
                                                                                    totalBytes:totalBytesExpectedToWrite]
                                       autorelease];
    
    if ([self.delegate respondsToSelector:@selector(liveUploadOperationProgressed:operation:)]) 
    {
        [self.delegate liveUploadOperationProgressed:progress operation:self.publicOperation];
    }
}

#pragma mark query upload location

- (void)queryUploadLocation
{
    if (self.completed) {
        return;
    }
    
    if ([UrlHelper isFullUrl:self.path]) 
    {
        _uploadPath = [self.path retain];
        [self sendRequest];
    }
    else
    {
        _queryUploadLocationOp = [[self.liveClient sendRequestWithMethod:@"GET" 
                                                                    path:self.path 
                                                                jsonBody:nil 
                                                                delegate:self 
                                                               userState:@"QUERY_UPLOAD_LOCATION"] 
                                  retain];
    };
}

- (void)liveOperationSucceeded:(LiveOperation *)operation
{
    NSString *encodedFileNamePath = [_fileName stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    [_uploadPath release];
    _uploadPath = [[[operation.result valueForKey:@"upload_location"] 
                    stringByAppendingString:encodedFileNamePath] retain];
    
    if ([StringHelper isNullOrEmpty:_uploadPath])
    {
        NSError *error = [LiveApiHelper createAPIError:LIVE_ERROR_CODE_S_REQUEST_FAILED 
                                               message:LIVE_ERROR_DESC_UPLOAD_FAIL_QUERY
                                            innerError:nil];
        [self operationFailed:error];
    }
    else
    {
        [self sendRequest];
    }
}

- (void)liveOperationFailed:(NSError *)error
                  operation:(LiveOperation*)operation
{
    [self operationFailed:error];
}


- (void) authCompleted:(LiveConnectSessionStatus)status
               session:(LiveConnectSession *)session
             userState:(id)userState
{
    [self queryUploadLocation];
}

- (void) dismissCurrentRequest
{
    [_queryUploadLocationOp cancel];
    
    [super dismissCurrentRequest];
}

@end
