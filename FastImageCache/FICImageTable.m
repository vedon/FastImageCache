//
//  FICImageTable.m
//  FastImageCache
//
//  Copyright (c) 2013 Path, Inc.
//  See LICENSE for full license agreement.
//

#import "FICImageTable.h"
#import "FICImageFormat.h"
#import "FICImageCache.h"
#import "FICImageTableChunk.h"
#import "FICImageTableEntry.h"
#import "FICUtilities.h"

#import "FICImageCache+FICErrorLogging.h"

#pragma mark External Definitions

NSString *const FICImageTableEntryDataVersionKey = @"FICImageTableEntryDataVersionKey";
NSString *const FICImageTableScreenScaleKey = @"FICImageTableScreenScaleKey";

#pragma mark - Internal Definitions

static NSString *const FICImageTableMetadataFileExtension = @"metadata";
static NSString *const FICImageTableFileExtension = @"imageTable";

static NSString *const FICImageTableMetadataKey = @"metadata";
static NSString *const FICImageTableMRUIndexKey = @"mruIndex";
static NSString *const FICImageTableContextUUIDKey = @"contextUUID";
static NSString *const FICImageTableIndexKey = @"tableIndex";
static NSString *const FICImageTableFormatKey = @"format";

#pragma mark - Class Extension

@interface FICImageTable () {
    FICImageFormat *_imageFormat;
    CGFloat _screenScale;
    NSInteger _imageRowLength;
    
    NSString *_filePath;
    int _fileDescriptor;
    off_t _fileLength;
    
    NSUInteger _entryCount;
    NSInteger _entryLength;
    NSUInteger _entriesPerChunk;
    NSInteger _imageLength;
    
    size_t _chunkLength;
    NSInteger _chunkCount;
    
    NSMutableDictionary *_chunkDictionary;
    NSCountedSet *_chunkSet;

    NSRecursiveLock *_lock;
    CFMutableDictionaryRef _indexNumbers;
    
    // Image table metadata
    NSMutableDictionary *_indexMap;         // Key: entity UUID, value: integer index into the table file
    NSMutableDictionary *_sourceImageMap;   // Key: entity UUID, value: source image UUID
    NSMutableIndexSet *_occupiedIndexes;
    NSMutableOrderedSet *_MRUEntries;
    NSCountedSet *_inUseEntries;
    NSDictionary *_imageFormatDictionary;
}

@end

#pragma mark

@implementation FICImageTable

@synthesize imageFormat =_imageFormat;

#pragma mark - Property Accessors (Public)

- (NSString *)tableFilePath {
    NSString *tableFilePath = [[_imageFormat name] stringByAppendingPathExtension:FICImageTableFileExtension];
    tableFilePath = [[FICImageTable directoryPath] stringByAppendingPathComponent:tableFilePath];
    
    return tableFilePath;
}

- (NSString *)metadataFilePath {
    NSString *metadataFilePath = [[_imageFormat name] stringByAppendingPathExtension:FICImageTableMetadataFileExtension];
    metadataFilePath = [[FICImageTable directoryPath] stringByAppendingPathComponent:metadataFilePath];
    
    return metadataFilePath;
}

#pragma mark - Class-Level Definitions

+ (int)pageSize {
    static int __pageSize = 0;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __pageSize = getpagesize();
    });

    return __pageSize;
}

+ (NSString *)directoryPath {
    static NSString *__directoryPath = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        __directoryPath = [[[paths objectAtIndex:0] stringByAppendingPathComponent:@"ImageTables"] retain];
        
        NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];
        BOOL directoryExists = [fileManager fileExistsAtPath:__directoryPath];
        if (directoryExists == NO) {
            [fileManager createDirectoryAtPath:__directoryPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
    });
    
    return __directoryPath;
}

#pragma mark - Object Lifecycle

- (instancetype)initWithFormat:(FICImageFormat *)imageFormat {
    self = [super init];
    
    if (self != nil) {
        if (imageFormat == nil) {
            [NSException raise:NSInvalidArgumentException format:@"*** FIC Exception: %s must pass in an image format.", __PRETTY_FUNCTION__];
        }
        
        _lock = [[NSRecursiveLock alloc] init];
        _indexNumbers = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        
        _imageFormat = [imageFormat copy];
        _imageFormatDictionary = [[imageFormat dictionaryRepresentation] retain];
        
        _screenScale = [[UIScreen mainScreen] scale];
        
        CGSize pixelSize = [_imageFormat pixelSize];
        NSInteger bytesPerPixel = [_imageFormat bytesPerPixel];
        _imageRowLength = (NSInteger)FICByteAlignForCoreAnimation(pixelSize.width * bytesPerPixel);
        _imageLength = _imageRowLength * (NSInteger)pixelSize.height;
        
        _chunkDictionary = [[NSMutableDictionary alloc] init];
        _chunkSet = [[NSCountedSet alloc] init];

        _indexMap = [[NSMutableDictionary alloc] init];
        _occupiedIndexes = [[NSMutableIndexSet alloc] init];
        
        _MRUEntries = [[NSMutableOrderedSet alloc] init];
        _inUseEntries = [[NSCountedSet alloc] init];

        _sourceImageMap = [[NSMutableDictionary alloc] init];
        
        _filePath = [[self tableFilePath] copy];
        
        [self _loadMetadata];
        
        _fileDescriptor = open([_filePath fileSystemRepresentation], O_RDWR | O_CREAT, 0666);
        
        if (_fileDescriptor >= 0) {
            // The size of each entry in the table needs to be page-aligned. This will cause each entry to have a page-aligned base
            // address, which will help us avoid Core Animation having to copy our images when we eventually set them on layers.
            _entryLength = (NSInteger)FICByteAlign(_imageLength + sizeof(FICImageTableEntryMetadata), [FICImageTable pageSize]);
            
            // Each chunk will map in n entries. Try to keep the chunkLength around 2MB.
            NSInteger goalChunkLength = 2 * (1024 * 1024);
            NSInteger goalEntriesPerChunk = goalChunkLength / _entryLength;
            _entriesPerChunk = MAX(4, goalEntriesPerChunk);
            if ([self _maximumCount] > [_imageFormat maximumCount]) {
                NSString *message = [NSString stringWithFormat:@"*** FIC Warning: growing desired maximumCount (%ld) for format %@ to fill a chunk (%d)", (long)[_imageFormat maximumCount], [_imageFormat name], [self _maximumCount]];
                [[FICImageCache sharedImageCache] _logMessage:message];
            }
            _chunkLength = (size_t)(_entryLength * _entriesPerChunk);
            
            _fileLength = lseek(_fileDescriptor, 0, SEEK_END);
            _entryCount = (NSInteger)(_fileLength / _entryLength);
            _chunkCount = (_entryCount + _entriesPerChunk - 1) / _entriesPerChunk;
            
            if ([_indexMap count] > _entryCount) {
                // It's possible that someone deleted the image table file but left behind the metadata file. If this happens, the metadata
                // will obviously become out of sync with the image table file, so we need to reset the image table.
                [self reset];
            }
        } else {
            // If something goes wrong and we can't open the image table file, then we have no choice but to release and nil self.
            NSString *message = [NSString stringWithFormat:@"*** FIC Error: %s could not open the image table file at path %@. The image table was not created.", __PRETTY_FUNCTION__, _filePath];
            [[FICImageCache sharedImageCache] _logMessage:message];
            
            [self release];
            self = nil;
        }    
    }
    
    return self;
}

- (instancetype)init {
    return [self initWithFormat:nil];
}

- (void)dealloc {
    [_imageFormat release];
    [_filePath release];
    
    [_indexMap release];
    [_occupiedIndexes release];
    [_MRUEntries release];
    [_sourceImageMap release];
    [_imageFormatDictionary release];
    [_chunkDictionary release];
    [_chunkSet release];
    
    if (_fileDescriptor >= 0) {
        close(_fileDescriptor);
    }
    
    [_lock release];
    
    [super dealloc];
}

#pragma mark - Working with Chunks

- (FICImageTableChunk *)_cachedChunkAtIndex:(NSInteger)index {
    return [_chunkDictionary objectForKey:@(index)];
}

- (void)_setChunk:(FICImageTableChunk *)chunk index:(NSInteger)index {
    NSNumber *indexNumber = @(index);
    if (chunk != nil) {
        [_chunkDictionary setObject:chunk forKey:indexNumber];
    } else {
        [_chunkDictionary removeObjectForKey:indexNumber];
    }
}

- (FICImageTableChunk *)_chunkAtIndex:(NSInteger)index {
    FICImageTableChunk *chunk = nil;
    
    if (index < _chunkCount) {
        chunk = [[self _cachedChunkAtIndex:index] retain];
        
        if (chunk == nil) {
            size_t chunkLength = _chunkLength;
            off_t chunkOffset = index * (off_t)_chunkLength;
            if (chunkOffset + chunkLength > _fileLength) {
                chunkLength = (size_t)(_fileLength - chunkOffset);
            }
                    
            chunk = [[FICImageTableChunk alloc] initWithImageTable:self fileDescriptor:_fileDescriptor index:index length:chunkLength];
            [self _setChunk:chunk index:index];
        }
    }
    
    if (!chunk) {
        NSString *message = [NSString stringWithFormat:@"*** FIC Error: %s failed to get chunk for index %ld.", __PRETTY_FUNCTION__, (long)index];
        [[FICImageCache sharedImageCache] _logMessage:message];
    }
    
    return [chunk autorelease];
}

- (void)_chunkWillBeDeallocated:(FICImageTableChunk *)chunk {
    [_lock lock];
    
    [self _setChunk:nil index:[chunk index]];
    
    [_lock unlock];
}

#pragma mark - Storing, Retrieving, and Deleting Entries

- (void)setEntryForEntityUUID:(NSString *)entityUUID sourceImageUUID:(NSString *)sourceImageUUID imageDrawingBlock:(FICEntityImageDrawingBlock)imageDrawingBlock {
    if (entityUUID != nil && sourceImageUUID != nil && imageDrawingBlock != NULL) {
        [_lock lock];
        
        NSInteger newEntryIndex = [self _indexOfEntryForEntityUUID:entityUUID];
        if (newEntryIndex == NSNotFound) {
            newEntryIndex = [self _nextEntryIndex];
            
            if (newEntryIndex >= _entryCount) {
                NSInteger newEntryCount = _entryCount + MAX(_entriesPerChunk, newEntryIndex - _entryCount + 1);
                [self _setEntryCount:newEntryCount];
            }
        }
        
        if (newEntryIndex < _entryCount) {
            CGSize pixelSize = [_imageFormat pixelSize];
            CGBitmapInfo bitmapInfo = [_imageFormat bitmapInfo];
            CGColorSpaceRef colorSpace = [_imageFormat isGrayscale] ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB();
            NSInteger bitsPerComponent = [_imageFormat bitsPerComponent];
            
            // Create context whose backing store *is* the mapped file data
            FICImageTableEntry *entryData = [self _entryDataAtIndex:newEntryIndex];
            if (entryData) {
                [entryData setEntityUUIDBytes:FICUUIDBytesWithString(entityUUID)];
                [entryData setSourceImageUUIDBytes:FICUUIDBytesWithString(sourceImageUUID)];
                
                // Update our book-keeping
                [_indexMap setObject:[NSNumber numberWithUnsignedInteger:newEntryIndex] forKey:entityUUID];
                [_occupiedIndexes addIndex:newEntryIndex];
                [_sourceImageMap setObject:sourceImageUUID forKey:entityUUID];
                
                // Update MRU array
                [self _entryWasAccessedWithEntityUUID:entityUUID];
                [self saveMetadata];
                
                // Unique, unchanging pointer for this entry's index
                NSNumber *indexNumber = [self _numberForEntryAtIndex:newEntryIndex];
                
                // Relinquish the image table lock before calling potentially slow imageDrawingBlock to unblock other FIC operations
                [_lock unlock];
                
                CGContextRef context = CGBitmapContextCreate([entryData bytes], pixelSize.width, pixelSize.height, bitsPerComponent, _imageRowLength, colorSpace, bitmapInfo);
                CGContextTranslateCTM(context, 0, pixelSize.height);
                CGContextScaleCTM(context, _screenScale, -_screenScale);
                
                @synchronized(indexNumber) {
                    // Call drawing block to allow client to draw into the context
                    imageDrawingBlock(context, [_imageFormat imageSize]);
                    CGContextRelease(context);
                
                    // Write the data back to the filesystem
                    [entryData flush];
                }
            } else {
                [_lock unlock];
            }
            CGColorSpaceRelease(colorSpace);
        } else {
            [_lock unlock];
        }
    }
}

- (UIImage *)newImageForEntityUUID:(NSString *)entityUUID sourceImageUUID:(NSString *)sourceImageUUID preheatData:(BOOL)preheatData {
    UIImage *image = nil;
    
    if (entityUUID != nil && sourceImageUUID != nil) {
        [_lock lock];

        FICImageTableEntry *entryData = [self _entryDataForEntityUUID:entityUUID];
        if (entryData != nil) {
            NSString *entryEntityUUID = FICStringWithUUIDBytes([entryData entityUUIDBytes]);
            NSString *entrySourceImageUUID = FICStringWithUUIDBytes([entryData sourceImageUUIDBytes]);
            BOOL entityUUIDIsCorrect = entityUUID == nil || [entityUUID isEqualToString:entryEntityUUID];
            BOOL sourceImageUUIDIsCorrect = sourceImageUUID == nil || [sourceImageUUID isEqualToString:entrySourceImageUUID];
            
            NSNumber *indexNumber = [self _numberForEntryAtIndex:[entryData index]];
            @synchronized(indexNumber) {
                if (entityUUIDIsCorrect == NO || sourceImageUUIDIsCorrect == NO) {
                    // The UUIDs don't match, so we need to invalidate the entry.
                    [self deleteEntryForEntityUUID:entityUUID];
                } else {
                    [self _entryWasAccessedWithEntityUUID:entityUUID];
                    
                    [entryData retain]; // Released by _FICReleaseImageData
                    
                    // Create CGImageRef whose backing store *is* the mapped image table entry. We avoid a memcpy this way.
                    CGDataProviderRef dataProvider = CGDataProviderCreateWithData((void *)entryData, [entryData bytes], [entryData imageLength], _FICReleaseImageData);
                    
                    [_inUseEntries addObject:entityUUID];

                    [entryData executeBlockOnDealloc:^{
                        [self removeInUseForEntityUUID:entityUUID];
                    }];
                    
                    CGSize pixelSize = [_imageFormat pixelSize];
                    CGBitmapInfo bitmapInfo = [_imageFormat bitmapInfo];
                    NSInteger bitsPerComponent = [_imageFormat bitsPerComponent];
                    NSInteger bitsPerPixel = [_imageFormat bytesPerPixel] * 8;
                    CGColorSpaceRef colorSpace = [_imageFormat isGrayscale] ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB();
                    
                    CGImageRef imageRef = CGImageCreate(pixelSize.width, pixelSize.height, bitsPerComponent, bitsPerPixel, _imageRowLength, colorSpace, bitmapInfo, dataProvider, NULL, false, (CGColorRenderingIntent)0);
                    CGDataProviderRelease(dataProvider);
                    CGColorSpaceRelease(colorSpace);
                    
                    if (imageRef != NULL) {
                        image = [[UIImage alloc] initWithCGImage:imageRef scale:_screenScale orientation:UIImageOrientationUp];
                        CGImageRelease(imageRef);
                    } else {
                        NSString *message = [NSString stringWithFormat:@"*** FIC Error: %s could not create a new CGImageRef for entity UUID %@.", __PRETTY_FUNCTION__, entityUUID];
                        [[FICImageCache sharedImageCache] _logMessage:message];
                    }
                    
                    if (image != nil && preheatData) {
                        [entryData preheat];
                    }
                }
            }
        }
        
        [_lock unlock];
    }
    
    return image;
}

static void _FICReleaseImageData(void *info, const void *data, size_t size) {
    if (info) {
        CFRelease(info);
    }
}

- (void)removeInUseForEntityUUID:(NSString *)entityUUID {
    [_lock lock];
    [_inUseEntries removeObject:entityUUID];
    [_lock unlock];
}

- (void)deleteEntryForEntityUUID:(NSString *)entityUUID {
    if (entityUUID != nil) {
        [_lock lock];
        
        NSInteger index = [self _indexOfEntryForEntityUUID:entityUUID];
        if (index != NSNotFound) {
            [_sourceImageMap removeObjectForKey:entityUUID];
            [_indexMap removeObjectForKey:entityUUID];
            [_occupiedIndexes removeIndex:index];
            NSInteger index = [_MRUEntries indexOfObject:entityUUID];
            if (index != NSNotFound) {
                [_MRUEntries removeObjectAtIndex:index];
            }
            [self saveMetadata];
        }
        
        [_lock unlock];
    }
}

#pragma mark - Checking for Entry Existence

- (BOOL)entryExistsForEntityUUID:(NSString *)entityUUID sourceImageUUID:(NSString *)sourceImageUUID {
    BOOL imageExists = NO;

    [_lock lock];
    
    FICImageTableEntry *entryData = [self _entryDataForEntityUUID:entityUUID];
    if (entryData != nil && sourceImageUUID != nil) {
        NSString *existingEntityUUID = FICStringWithUUIDBytes([entryData entityUUIDBytes]);
        BOOL entityUUIDIsCorrect = [entityUUID isEqualToString:existingEntityUUID];
        
        NSString *existingSourceImageUUID = FICStringWithUUIDBytes([entryData sourceImageUUIDBytes]);
        BOOL sourceImageUUIDIsCorrect = [sourceImageUUID isEqualToString:existingSourceImageUUID];
        
        if (entityUUIDIsCorrect == NO || sourceImageUUIDIsCorrect == NO) {
            // The source image UUIDs don't match, so the image data should be deleted for this entity.
            [self deleteEntryForEntityUUID:entityUUID];
            entryData = nil;
        }
    }
    
    [_lock unlock];
    
    imageExists = entryData != nil;
    
    return imageExists;
}

#pragma mark - Working with Entries

- (int)_maximumCount {
    return (int)MAX([_imageFormat maximumCount], _entriesPerChunk);
}

- (void)_setEntryCount:(NSInteger)entryCount {
    if (entryCount != _entryCount && _entriesPerChunk > 0) {
        off_t fileLength = entryCount * _entryLength;
        int result = ftruncate(_fileDescriptor, fileLength);
        
        if (result != 0) {
            NSString *message = [NSString stringWithFormat:@"*** FIC Error: %s ftruncate returned %d, error = %d, fd = %d, filePath = %@, length = %lld", __PRETTY_FUNCTION__, result, errno, _fileDescriptor, _filePath, fileLength];
            [[FICImageCache sharedImageCache] _logMessage:message];
        } else {
            _fileLength = fileLength;
            _entryCount = entryCount;
            _chunkCount = (_entryCount + _entriesPerChunk - 1) / _entriesPerChunk;
        }
    }
}

- (FICImageTableEntry *)_entryDataAtIndex:(NSInteger)index {
    FICImageTableEntry *entryData = nil;
    
    [_lock lock];
    
    if (index < _entryCount) {
        off_t entryOffset = index * _entryLength;
        size_t chunkIndex = (size_t)(entryOffset / _chunkLength);
        
        FICImageTableChunk *chunk = [self _chunkAtIndex:chunkIndex];
        if (chunk != nil) {
            off_t chunkOffset = chunkIndex * _chunkLength;
            off_t entryOffsetInChunk = entryOffset - chunkOffset;
            void *mappedChunkAddress = [chunk bytes];
            void *mappedEntryAddress = mappedChunkAddress + entryOffsetInChunk;
            entryData = [[FICImageTableEntry alloc] initWithImageTableChunk:chunk bytes:mappedEntryAddress length:_entryLength];
            [entryData setIndex:index];
            
            [_chunkSet addObject:chunk];
            
            [entryData executeBlockOnDealloc:^{
                [self _entryWasDeallocatedFromChunk:chunk];
            }];
        }
    }
    
    [_lock unlock];
    
    if (!entryData) {
        NSString *message = [NSString stringWithFormat:@"*** FIC Error: %s failed to get entry for index %ld.", __PRETTY_FUNCTION__, (long)index];
        [[FICImageCache sharedImageCache] _logMessage:message];
    }
    
    return [entryData autorelease];
}

- (void)_entryWasDeallocatedFromChunk:(FICImageTableChunk *)chunk {
    [_lock lock];
    [_chunkSet removeObject:chunk];
    if ([_chunkSet countForObject:chunk] == 0) {
        [self _setChunk:nil index:[chunk index]];
    }
    [_lock unlock];
}

- (NSInteger)_nextEntryIndex {
    NSMutableIndexSet *unoccupiedIndexes = [[NSMutableIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, _entryCount)];
    [unoccupiedIndexes removeIndexes:_occupiedIndexes];
    
    NSInteger index = [unoccupiedIndexes firstIndex];
    if (index == NSNotFound) {
        index = _entryCount;
    }
    [unoccupiedIndexes release];
    
    if (index >= [self _maximumCount] && [_MRUEntries count]) {
        // Evict the oldest/least-recently accessed entry here

        NSString *oldestEvictableEntityUUID = [self oldestEvictableEntityUUID];
        if (oldestEvictableEntityUUID) {
            [self deleteEntryForEntityUUID:oldestEvictableEntityUUID];
            index = [self _nextEntryIndex];
        }
    }

    if (index >= [self _maximumCount]) {
        NSString *message = [NSString stringWithFormat:@"FICImageTable - unable to evict entry from table '%@' to make room. New index %ld, desired max %d", [_imageFormat name], (long)index, [self _maximumCount]];
        [[FICImageCache sharedImageCache] _logMessage:message];
    }
    
    return index;
}

- (NSString *)oldestEvictableEntityUUID {
    NSString *uuid = nil;
    for (NSInteger i = [_MRUEntries count] - 1; i >= 0; i--) {
        NSString *candidateUUID = [_MRUEntries objectAtIndex:i];
        if (![_inUseEntries containsObject:candidateUUID]) {
            uuid = candidateUUID;
            break;
        }
    }

    return uuid;
}

- (NSInteger)_indexOfEntryForEntityUUID:(NSString *)entityUUID {
    NSInteger index = NSNotFound;
    if (_indexMap != nil && entityUUID != nil) {
        NSNumber *indexNumber = [_indexMap objectForKey:entityUUID];
        index = indexNumber ? [indexNumber integerValue] : NSNotFound;
        
        if (index != NSNotFound && index >= _entryCount) {
            [_indexMap removeObjectForKey:entityUUID];
            [_occupiedIndexes removeIndex:index];
            [_sourceImageMap removeObjectForKey:entityUUID];
            index = NSNotFound;
        }
    }
    
    return index;
}

- (FICImageTableEntry *)_entryDataForEntityUUID:(NSString *)entityUUID {
    FICImageTableEntry *entryData = nil;
    NSInteger index = [self _indexOfEntryForEntityUUID:entityUUID];
    if (index != NSNotFound) {
        entryData = [self _entryDataAtIndex:index];
    }
    
    return entryData;
}

- (void)_entryWasAccessedWithEntityUUID:(NSString *)entityUUID {
    // Update MRU array
    NSInteger index = [_MRUEntries indexOfObject:entityUUID];
    if (index == NSNotFound) {
        [_MRUEntries insertObject:entityUUID atIndex:0];
    } else if (index != 0) {
        [entityUUID retain];
        [_MRUEntries removeObjectAtIndex:index];
        [_MRUEntries insertObject:entityUUID atIndex:0];
        [entityUUID release];
    }
}

// Unchanging pointer value for a given entry index to synchronize on
- (NSNumber *)_numberForEntryAtIndex:(NSInteger)index {
    NSNumber *resultNumber = (__bridge id)CFDictionaryGetValue(_indexNumbers, (const void *)index);
    if (!resultNumber) {
        resultNumber = [NSNumber numberWithInteger:index];
        CFDictionarySetValue(_indexNumbers, (const void *)index, (__bridge void *)resultNumber);
    }
    return resultNumber;
}

#pragma mark - Working with Metadata

- (void)saveMetadata {
    [_lock lock];
    
    NSMutableDictionary *entryMetadata = [NSMutableDictionary dictionary];
    for (NSString *entityUUID in [_indexMap allKeys]) {
        NSMutableDictionary *entryDict = [entryMetadata objectForKey:entityUUID];
        if (!entryDict) {
            entryDict = [[NSMutableDictionary alloc] init];
            [entryMetadata setObject:entryDict forKey:entityUUID];
            [entryDict release];
        }
        NSNumber *tableIndexVal = [_indexMap objectForKey:entityUUID];
        NSString *contextUUID = [_sourceImageMap objectForKey:entityUUID];
        NSInteger mruIndex = [_MRUEntries indexOfObject:entityUUID];
        
        [entryDict setValue:tableIndexVal forKey:FICImageTableIndexKey];
        [entryDict setValue:contextUUID forKey:FICImageTableContextUUIDKey];
        if (mruIndex != NSNotFound) {
            [entryDict setValue:[NSNumber numberWithInteger:mruIndex] forKey:FICImageTableMRUIndexKey];
        }
    }
    
    NSDictionary *metadataDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                        entryMetadata, FICImageTableMetadataKey,
                                        [[_imageFormatDictionary copy] autorelease], FICImageTableFormatKey, nil];
    
    [_lock unlock];
    
    static dispatch_queue_t __metadataQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __metadataQueue = dispatch_queue_create("com.path.FastImageCache.ImageTableMetadataQueue", NULL);
    });
    
    dispatch_async(__metadataQueue, ^{
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:metadataDictionary format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        BOOL fileWriteResult = [data writeToFile:[self metadataFilePath] atomically:NO];
        if (fileWriteResult == NO) {
            NSString *message = [NSString stringWithFormat:@"*** FIC Error: %s couldn't write metadata for format %@", __PRETTY_FUNCTION__, [_imageFormat name]];
            [[FICImageCache sharedImageCache] _logMessage:message];
        }
    });
}

- (void)_loadMetadata {
    NSString *metadataFilePath = [[_filePath stringByDeletingPathExtension] stringByAppendingPathExtension:FICImageTableMetadataFileExtension];
    NSData *metadataData = [NSData dataWithContentsOfMappedFile:metadataFilePath];
    if (metadataData != nil) {
        NSDictionary *metadataDictionary = (NSDictionary *)[NSPropertyListSerialization propertyListWithData:metadataData options:0 format:NULL error:NULL];
        NSDictionary *formatDictionary = [metadataDictionary objectForKey:FICImageTableFormatKey];
        if ([formatDictionary isEqualToDictionary:_imageFormatDictionary] == NO) {
            // Something about this image format has changed, so the existing metadata is no longer valid. The image table file
            // must be deleted and recreated.
            [[NSFileManager defaultManager] removeItemAtPath:_filePath error:NULL];
            [[NSFileManager defaultManager] removeItemAtPath:metadataFilePath error:NULL];
            metadataDictionary = nil;
            
            NSString *message = [NSString stringWithFormat:@"*** FIC Notice: Image format %@ has changed; deleting data and starting over.", [_imageFormat name]];
            [[FICImageCache sharedImageCache] _logMessage:message];
        }
        
        NSDictionary *tableMetadata = [metadataDictionary objectForKey:FICImageTableMetadataKey];
        NSInteger count = [tableMetadata count];
        NSMutableArray *mruArray = [NSMutableArray arrayWithCapacity:count];
        for (NSInteger i = 0; i < count; i++) {
            [mruArray addObject:[NSNull null]];
        }
        NSMutableIndexSet *nullIndexes = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, count)];
        
        [_indexMap removeAllObjects];
        [_sourceImageMap removeAllObjects];
        [_MRUEntries removeAllObjects];
        
        for (NSString *entityUUID in [tableMetadata allKeys]) {
            NSDictionary *entryDict = [tableMetadata objectForKey:entityUUID];
            [_indexMap setValue:[entryDict objectForKey:FICImageTableIndexKey] forKey:entityUUID];
            [_sourceImageMap setValue:[entryDict objectForKey:FICImageTableContextUUIDKey] forKey:entityUUID];
            NSNumber *mruIndexVal = [entryDict objectForKey:FICImageTableMRUIndexKey];
            if (mruIndexVal) {
                NSInteger mruIndex = [mruIndexVal integerValue];
                [mruArray replaceObjectAtIndex:mruIndex withObject:entityUUID];
                [nullIndexes removeIndex:mruIndex];
            }
        }
        
        NSUInteger index = [nullIndexes lastIndex];
        while (index != NSNotFound) {
            [mruArray removeObjectAtIndex:index];
            index = [nullIndexes indexLessThanIndex:index];
        }
        [_MRUEntries addObjectsFromArray:mruArray];
        
        for (NSNumber *index in [_indexMap allValues]) {
            [_occupiedIndexes addIndex:[index intValue]];
        }
    }
}

#pragma mark - Resetting the Image Table

- (void)reset {
    [_lock lock];
    
    [_indexMap removeAllObjects];
    [_occupiedIndexes removeAllIndexes];
    [_inUseEntries removeAllObjects];
    [_MRUEntries removeAllObjects];
    [_sourceImageMap removeAllObjects];
    
    [self _setEntryCount:0];
    [self saveMetadata];
    
    [_lock unlock];
}

@end
