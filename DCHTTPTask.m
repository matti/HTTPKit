////////////////////////////////////////////////////////////////////////////////////////////////////
//
//  DCHTTPTask.m
//
//  Created by Dalton Cherry on 5/5/14.
//
////////////////////////////////////////////////////////////////////////////////////////////////////

#import "DCHTTPTask.h"
#import "DCHTTPUpload.h"

@interface DCHTTPTask ()

@property(nonatomic,strong)DCAsyncTask asyncTask;
@property(nonatomic,strong)NSMutableDictionary *serializers;
@property(nonatomic,strong)DCAsyncTaskSuccess backgroundSuccess;
@property(nonatomic,strong)DCAsyncTaskFailure backgroundFailure;
@property(nonatomic,weak)NSURLSessionTask *backgroundTask;
@property(nonatomic,strong)DCHTTPTaskProgress progressBlock;

@end

@implementation DCHTTPTask

static NSString *backgroundIdentifierRoot = @"com.vluxe.dchttpkit.task";
////////////////////////////////////////////////////////////////////////////////////////////////////
- (instancetype)init
{
    self = [super init];
    if(self)
    {
        self.HTTPMethod = @"GET";
    }
    return self;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)willStart
{
    NSError *error = nil;
    NSURLRequest *request = [self.requestSerializer requestBySerializingUrl:[NSURL URLWithString:self.url]
                                                                     method:self.HTTPMethod
                                                                 parameters:self.parameters error:&error];
    if(error)
    {
        self.asyncTask = ^(DCAsyncTaskSuccess success, DCAsyncTaskFailure failure) {
            failure(error);
        };
        return;
    }
    if((self.isDownload || self.isUpload) && !_backgroundIdentifier) {
        _backgroundIdentifier = [self randomIdentifer];
    }
    __weak DCHTTPTask *weakSelf = self;
    self.asyncTask = ^(DCAsyncTaskSuccess success, DCAsyncTaskFailure failure) {
        if(weakSelf.isDownload || weakSelf.isUpload) {
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfiguration:weakSelf.backgroundIdentifier];
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:weakSelf delegateQueue:nil];
            NSURLSessionTask *task = nil;
            if(weakSelf.isDownload) {
                task = [session downloadTaskWithRequest:request];
            } else {
                DCHTTPUpload *upload = nil;
                for(id key in weakSelf.parameters)
                {
                    id val = weakSelf.parameters[key];
                    if([val isKindOfClass:[DCHTTPUpload class]]) {
                        upload = val;
                    }
                }
                task = [session uploadTaskWithRequest:request fromFile:upload.fileURL];
            }
            //we do some block awesomeness here and wait for the delegate to finish, then notify that the download task finished
            weakSelf.backgroundSuccess = success;
            weakSelf.backgroundFailure = failure;
            weakSelf.backgroundTask = task;
            [task resume];
        } else {
            NSURLSession *session = [NSURLSession sharedSession];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                                    completionHandler:
                                          ^(NSData *data, NSURLResponse *response, NSError *error) {
                                              if(error) {
                                                  failure(error);
                                              } else {
                                                  DCHTTPResponse *payload = [DCHTTPResponse new];
                                                  payload.mimeType = response.MIMEType;
                                                  payload.suggestedFilename = response.suggestedFilename;
                                                  if([response isKindOfClass:[NSHTTPURLResponse class]])
                                                      payload.headers = [(NSHTTPURLResponse*)response allHeaderFields];
                                                  
                                                  payload.responseObject = data;
                                                  id<DCHTTPResponseSerializerDelegate>serializer =
                                                  [weakSelf serializerForContentType:payload.headers[@"Content-Type"]];
                                                  if(serializer) {
                                                      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                                          NSError *error = nil;
                                                          payload.responseObject = [serializer responseObjectFromResponse:response data:data error:&error];
                                                          dispatch_async(dispatch_get_main_queue(),^{
                                                              if(error) {
                                                                  failure(error);
                                                              } else {
                                                                  success(payload);
                                                              }
                                                          });
                                                      });
                                                  }
                                                  else {
                                                      success(payload);
                                                  }
                                              }
                                          }];
            
            [task resume];
        }
    };
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(NSString*)randomIdentifer
{
    return [NSString stringWithFormat:@"%@.%@",backgroundIdentifierRoot,[self randomStringWithLength:14]];
}
////////////////////////////////////////////////////////////////////////////////////////////////////
NSString *letters = @"abcdefghijklmnopqrstuvwxyz"; //ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
-(NSString *)randomStringWithLength:(NSInteger)len
{
    
    NSMutableString *randomString = [NSMutableString stringWithCapacity: len];
    
    for(NSInteger i = 0; i < len; i++) {
        [randomString appendFormat: @"%C", [letters characterAtIndex: arc4random() % [letters length]]];
    }
    return randomString;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(DCHTTPRequestSerializer*)requestSerializer
{
    if(!_requestSerializer) {
        _requestSerializer = [DCHTTPRequestSerializer new];
    }
    return _requestSerializer;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)setResponseSerializer:(id<DCHTTPResponseSerializerDelegate>)responseSerializer forContentType:(NSString*)contentType
{
    if(!self.serializers)
        self.serializers = [NSMutableDictionary new];
    [self.serializers setObject:responseSerializer forKey:contentType];
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)setProgress:(DCHTTPTaskProgress)block
{
    self.progressBlock = block;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)setDownloadUrl:(NSURL *)downloadUrl
{
    _downloadUrl = downloadUrl;
    self.download = YES;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(id<DCHTTPResponseSerializerDelegate>)serializerForContentType:(NSString*)type
{
    id<DCHTTPResponseSerializerDelegate>serializer = self.responseSerializer;
    if(self.serializers.count > 0) {
        id<DCHTTPResponseSerializerDelegate>otherSerializer = self.serializers[type];
        if(otherSerializer) {
            serializer = otherSerializer;
        }
    }
    return serializer;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)setDownload:(BOOL)download
{
    _download = download;
    if(!_backgroundIdentifier)
        _backgroundIdentifier = [self randomIdentifer];
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)setUpload:(BOOL)upload
{
    _upload = upload;
    if(!_backgroundIdentifier)
        _backgroundIdentifier = [self randomIdentifer];
}
////////////////////////////////////////////////////////////////////////////////////////////////////

#pragma mark - URL session download delegate methods
////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(error)
    {
        if(self.backgroundFailure)
            self.backgroundFailure(error);
        self.backgroundFailure = self.backgroundSuccess = nil;
    }
}
////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)downloadURL
{
    if(self.backgroundSuccess)
    {
        DCHTTPResponse *payload = [DCHTTPResponse new];
        payload.mimeType = downloadTask.response.MIMEType;
        payload.suggestedFilename = downloadTask.response.suggestedFilename;
        if([downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
            payload.headers = [(NSHTTPURLResponse*)downloadTask.response allHeaderFields];
        }
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *saveUrl = self.downloadUrl;
        if(!self.downloadUrl) {
            
            NSString *fileName = payload.suggestedFilename;
            if(!fileName)
                fileName = [[[downloadTask originalRequest] URL] lastPathComponent];
            saveUrl = [NSURL fileURLWithPath:[self docDirectory:fileName]];
        }
        [fileManager removeItemAtURL:saveUrl error:nil];
        [fileManager moveItemAtURL:downloadURL toURL:saveUrl error:nil];
        payload.responseObject = saveUrl;
        self.backgroundSuccess(payload);
        self.backgroundFailure = self.backgroundSuccess = nil;
    }
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(NSString*)docDirectory:(NSString*)name
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [NSString stringWithFormat:@"%@/%@",[paths objectAtIndex:0],name];
}
////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if(self.progressBlock)
    {
        if (downloadTask == self.backgroundTask) {
            double increment = 100.0f/totalBytesExpectedToWrite;
            double current = (increment*totalBytesWritten);
            current = current*0.01f;
            if(current > 1)
                current = 1;
            //NSLog(@"DownloadTask: %@ progress: %lf", downloadTask, current);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressBlock(current);
            });
        }
    }
}
////////////////////////////////////////////////////////////////////////////////////////////////////
-(void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    if(self.progressBlock)
    {
        if (task == self.backgroundTask) {
            double increment = 100.0f/totalBytesExpectedToSend;
            double current = (increment*totalBytesSent);
            current = current*0.01f;
            if(current > 1)
                current = 1;
            //NSLog(@"uploadTask: %@ progress: %lf", task, current);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressBlock(current);
            });
        }
    }
}
////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    if(self.backgroundSuccess)
    {
        DCHTTPResponse *payload = [DCHTTPResponse new];
        payload.mimeType = dataTask.response.MIMEType;
        payload.suggestedFilename = dataTask.response.suggestedFilename;
        if([dataTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
            payload.headers = [(NSHTTPURLResponse*)dataTask.response allHeaderFields];
        }
        payload.responseObject = data;
        id<DCHTTPResponseSerializerDelegate>serializer = [self serializerForContentType:payload.headers[@"Content-Type"]];
        if(serializer) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *error = nil;
                payload.responseObject = [serializer responseObjectFromResponse:dataTask.response data:data error:&error];
                dispatch_async(dispatch_get_main_queue(),^{
                    if(error && self.backgroundFailure) {
                        self.backgroundFailure(error);
                    } else {
                        self.backgroundSuccess(payload);
                    }
                    self.backgroundFailure = self.backgroundSuccess = nil;
                });
            });
        }
        else {
            self.backgroundSuccess(payload);
            self.backgroundFailure = self.backgroundSuccess = nil;
        }
    }
}
////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    NSLog(@"done with something...");
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)GET:(NSString*)url parameters:(NSDictionary*)parameters
{
    DCHTTPTask *task = [[self class] taskWithURL:url parameters:parameters];
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)GET:(NSString*)url
{
    return [[self class] GET:url parameters:nil];
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)HEAD:(NSString*)url parameters:(NSDictionary*)parameters
{
    DCHTTPTask *task = [[self class] taskWithURL:url parameters:parameters];
    task.HTTPMethod = @"HEAD";
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)HEAD:(NSString*)url
{
    return [[self class] HEAD:url parameters:nil];
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)DELETE:(NSString*)url parameters:(NSDictionary*)parameters
{
    DCHTTPTask *task = [[self class] taskWithURL:url parameters:parameters];
    task.HTTPMethod = @"DELETE";
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)POST:(NSString*)url parameters:(NSDictionary*)parameters
{
    DCHTTPTask *task = [[self class] taskWithURL:url parameters:parameters];
    task.HTTPMethod = @"POST";
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)PUT:(NSString*)url parameters:(NSDictionary*)parameters
{
    DCHTTPTask *task = [[self class] taskWithURL:url parameters:parameters];
    task.HTTPMethod = @"PUT";
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)download:(NSString*)url toFile:(NSURL*)fileURL
{
    DCHTTPTask *task = [[self class] GET:url parameters:nil];
    task.downloadUrl = fileURL;
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////
+(DCHTTPTask*)taskWithURL:(NSString*)url parameters:(NSDictionary*)parameters
{
    DCHTTPTask *task = [DCHTTPTask new];
    task.url = url;
    task.parameters = parameters;
    return task;
}
////////////////////////////////////////////////////////////////////////////////////////////////////

@end

////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////
@implementation DCHTTPResponse

@end
