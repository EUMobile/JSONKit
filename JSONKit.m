//
//  JSONKit.m
//  http://github.com/johnezang/JSONKit
//  Licensed under the terms of the BSD License, as specified below.
//

/*
 Copyright (c) 2010, John Engelhart
 
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 * Neither the name of the Zang Industries nor the names of its
 contributors may be used to endorse or promote products derived from
 this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/


/*
  Acknowledgments:

  The bulk of the UTF8 / UTF32 conversion and verification comes
  from ConvertUTF.[hc].  It has been modified from the original sources.

  The original sources were obtained from http://www.unicode.org/.
  However, the web site no longer seems to host the files.  Instead,
  the Unicode FAQ http://www.unicode.org/faq//utf_bom.html#gen4
  points to International Components for Unicode (ICU)
  http://site.icu-project.org/ as an example of how to write a UTF
  converter.

  The decision to use the ConvertUTF.[ch] code was made to leverage
  "proven" code.  Hopefully the local modifications are bug free.

  The code in isValidCodePoint() is derived from the ICU code in
  utf.h for the macros U_IS_UNICODE_NONCHAR and U_IS_UNICODE_CHAR.

  From the original ConvertUTF.[ch]:

 * Copyright 2001-2004 Unicode, Inc.
 * 
 * Disclaimer
 * 
 * This source code is provided as is by Unicode, Inc. No claims are
 * made as to fitness for any particular purpose. No warranties of any
 * kind are expressed or implied. The recipient agrees to determine
 * applicability of information provided. If this file has been
 * purchased on magnetic or optical media from Unicode, Inc., the
 * sole remedy for any claim will be exchange of defective media
 * within 90 days of receipt.
 * 
 * Limitations on Rights to Redistribute This Code
 * 
 * Unicode, Inc. hereby grants the right to freely use the information
 * supplied in this file in the creation of products supporting the
 * Unicode Standard, and to make copies of this file in any form
 * for internal or external distribution as long as this notice
 * remains attached.

*/

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <sys/errno.h>
#include <math.h>

#import "JSONKit.h"

//#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFNumber.h>

//#import <Foundation/Foundation.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSException.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSScriptClassDescription.h>

// For DJB hash.
#define JK_HASH_INIT           (5381UL)

// Use __builtin_clz() instead of trailingBytesForUTF8[] table lookup.
#define JK_FAST_TRAILING_BYTES

// JK_CACHE_SLOTS must be a power of 2.  Default size is 1024 slots.
#define JK_CACHE_SLOTS_BITS    (10)
#define JK_CACHE_SLOTS         (1UL << JK_CACHE_SLOTS_BITS)
// JK_CACHE_PROBES is the number of probe attempts.
#define JK_CACHE_PROBES        (4UL)
// JK_INIT_CACHE_AGE must be (1 << AGE) - 1
#define JK_INIT_CACHE_AGE      (31)

// JK_TOKENBUFFER_SIZE is the default stack size for the temporary buffer used to hold "non-simple" strings (i.e., contains \ escapes)
#define JK_TOKENBUFFER_SIZE    (1024UL * 2UL)

// JK_STACK_OBJS is the default number of spaces reserved on the stack for temporarily storing pointers to Obj-C objects before they can be transfered to a NSArray / NSDictionary.
#define JK_STACK_OBJS          (1024UL * 1UL)

#define JK_JSONBUFFER_SIZE    (1024UL * 64UL)
#define JK_UTF8BUFFER_SIZE    (1024UL * 16UL)



#if       defined (__GNUC__) && (__GNUC__ >= 4)
#define JK_ATTRIBUTES(attr, ...)        __attribute__((attr, ##__VA_ARGS__))
#define JK_EXPECTED(cond, expect)       __builtin_expect((long)(cond), (expect))
#define JK_PREFETCH(ptr)                __builtin_prefetch(ptr)
#else  // defined (__GNUC__) && (__GNUC__ >= 4) 
#define JK_ATTRIBUTES(attr, ...)
#define JK_EXPECTED(cond, expect)       (cond)
#define JK_PREFETCH(ptr)
#endif // defined (__GNUC__) && (__GNUC__ >= 4) 

#define JK_STATIC_INLINE                         static __inline__ JK_ATTRIBUTES(always_inline)
#define JK_ALIGNED(arg)                                            JK_ATTRIBUTES(aligned(arg))
#define JK_UNUSED_ARG                                              JK_ATTRIBUTES(unused)
#define JK_WARN_UNUSED                                             JK_ATTRIBUTES(warn_unused_result)
#define JK_WARN_UNUSED_CONST                                       JK_ATTRIBUTES(warn_unused_result, const)
#define JK_WARN_UNUSED_PURE                                        JK_ATTRIBUTES(warn_unused_result, pure)
#define JK_WARN_UNUSED_SENTINEL                                    JK_ATTRIBUTES(warn_unused_result, sentinel)
#define JK_NONNULL_ARGS(arg, ...)                                  JK_ATTRIBUTES(nonnull(arg, ##__VA_ARGS__))
#define JK_WARN_UNUSED_NONNULL_ARGS(arg, ...)                      JK_ATTRIBUTES(warn_unused_result, nonnull(arg, ##__VA_ARGS__))
#define JK_WARN_UNUSED_CONST_NONNULL_ARGS(arg, ...)                JK_ATTRIBUTES(warn_unused_result, const, nonnull(arg, ##__VA_ARGS__))
#define JK_WARN_UNUSED_PURE_NONNULL_ARGS(arg, ...)                 JK_ATTRIBUTES(warn_unused_result, pure, nonnull(arg, ##__VA_ARGS__))

#if       defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)
#define JK_ALLOC_SIZE_NON_NULL_ARGS_WARN_UNUSED(as, nn, ...) JK_ATTRIBUTES(warn_unused_result, nonnull(nn, ##__VA_ARGS__), alloc_size(as))
#else  // defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)
#define JK_ALLOC_SIZE_NON_NULL_ARGS_WARN_UNUSED(as, nn, ...) JK_ATTRIBUTES(warn_unused_result, nonnull(nn, ##__VA_ARGS__))
#endif // defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)

typedef uint32_t UTF32; /* at least 32 bits */
typedef uint16_t UTF16; /* at least 16 bits */
typedef uint8_t  UTF8;  /* typically 8 bits */

typedef enum {
  conversionOK,           /* conversion successful */
  sourceExhausted,        /* partial character in source, but hit end */
  targetExhausted,        /* insuff. room in target for conversion */
  sourceIllegal           /* source sequence is illegal/malformed */
} ConversionResult;

enum {
  JKTokenTypeInvalid     = 0,
  JKTokenTypeNumber      = 1,
  JKTokenTypeString      = 2,
  JKTokenTypeObjectBegin = 3,
  JKTokenTypeObjectEnd   = 4,
  JKTokenTypeArrayBegin  = 5,
  JKTokenTypeArrayEnd    = 6,
  JKTokenTypeSeparator   = 7,
  JKTokenTypeComma       = 8,
  JKTokenTypeTrue        = 9,
  JKTokenTypeFalse       = 10,
  JKTokenTypeNull        = 11,
  JKTokenTypeWhiteSpace  = 12,
};

enum {
  JKManagedBufferOnStack        = 1,
  JKManagedBufferOnHeap         = 2,
  JKManagedBufferLocationMask   = (0x3),
  JKManagedBufferLocationShift  = (0),

  JKManagedBufferMustFree       = (1 << 2),
};

enum {
  JKObjectStackOnStack        = 1,
  JKObjectStackOnHeap         = 2,
  JKObjectStackLocationMask   = (0x3),
  JKObjectStackLocationShift  = (0),

  JKObjectStackMustFree       = (1 << 2),
};

// These are prime numbers to assist with hash slot probing.
enum {
  JKValueTypeNone             = 0,
  JKValueTypeString           = 5,
  JKValueTypeLongLong         = 7,
  JKValueTypeUnsignedLongLong = 11,
  JKValueTypeDouble           = 13,
};

enum {
  JSONNumberStateStart                 = 0,
  JSONNumberStateFinished              = 1,
  JSONNumberStateError                 = 2,
  JSONNumberStateWholeNumberStart      = 3,
  JSONNumberStateWholeNumberMinus      = 4,
  JSONNumberStateWholeNumberZero       = 5,
  JSONNumberStateWholeNumber           = 6,
  JSONNumberStatePeriod                = 7,
  JSONNumberStateFractionalNumberStart = 8,
  JSONNumberStateFractionalNumber      = 9,
  JSONNumberStateExponentStart         = 10,
  JSONNumberStateExponentPlusMinus     = 11,
  JSONNumberStateExponent              = 12,
};

enum {
  JSONStringStateStart                           = 0,
  JSONStringStateParsing                         = 1,
  JSONStringStateFinished                        = 2,
  JSONStringStateError                           = 3,
  JSONStringStateEscape                          = 4,
  JSONStringStateEscapedUnicode1                 = 5,
  JSONStringStateEscapedUnicode2                 = 6,
  JSONStringStateEscapedUnicode3                 = 7,
  JSONStringStateEscapedUnicode4                 = 8,
  JSONStringStateEscapedUnicodeSurrogate1        = 9,
  JSONStringStateEscapedUnicodeSurrogate2        = 10,
  JSONStringStateEscapedUnicodeSurrogate3        = 11,
  JSONStringStateEscapedUnicodeSurrogate4        = 12,
  JSONStringStateEscapedNeedEscapeForSurrogate   = 13,
  JSONStringStateEscapedNeedEscapedUForSurrogate = 14,
};

enum {
  JKParseAcceptValue      = (1 << 0),
  JKParseAcceptComma      = (1 << 1),
  JKParseAcceptEnd        = (1 << 2),
  JKParseAcceptValueOrEnd = (JKParseAcceptValue | JKParseAcceptEnd),
  JKParseAcceptCommaOrEnd = (JKParseAcceptComma | JKParseAcceptEnd),
};

#define UNI_REPLACEMENT_CHAR (UTF32)0x0000FFFD
#define UNI_MAX_BMP          (UTF32)0x0000FFFF
#define UNI_MAX_UTF16        (UTF32)0x0010FFFF
#define UNI_MAX_UTF32        (UTF32)0x7FFFFFFF
#define UNI_MAX_LEGAL_UTF32  (UTF32)0x0010FFFF
#define UNI_SUR_HIGH_START   (UTF32)0xD800
#define UNI_SUR_HIGH_END     (UTF32)0xDBFF
#define UNI_SUR_LOW_START    (UTF32)0xDC00
#define UNI_SUR_LOW_END      (UTF32)0xDFFF


#if !defined(JK_FAST_TRAILING_BYTES)
static const char trailingBytesForUTF8[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 3,3,3,3,3,3,3,3,4,4,4,4,5,5,5,5
};
#endif

static const UTF32 offsetsFromUTF8[6] = { 0x00000000UL, 0x00003080UL, 0x000E2080UL, 0x03C82080UL, 0xFA082080UL, 0x82082080UL };
static const UTF8  firstByteMark[7]   = { 0x00, 0x00, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC };


static void  jk_CFCallbackRelease(CFAllocatorRef allocator JK_UNUSED_ARG, const void *ptr) { CFRelease((CFTypeRef)ptr);                                                  }
static const CFArrayCallBacks           jk_transferOwnershipArrayCallBacks           =     { (CFIndex)0L, NULL, jk_CFCallbackRelease, CFCopyDescription, CFEqual         };
static const CFDictionaryKeyCallBacks   jk_transferOwnershipDictionaryKeyCallBacks   =     { (CFIndex)0L, NULL, jk_CFCallbackRelease, CFCopyDescription, CFEqual, CFHash };
static const CFDictionaryValueCallBacks jk_transferOwnershipDictionaryValueCallBacks =     { (CFIndex)0L, NULL, jk_CFCallbackRelease, CFCopyDescription, CFEqual         };


#define JK_AT_STRING_PTR(x)  (&((x)->stringBuffer.bytes.ptr[(x)->atIndex]))
#define JK_END_STRING_PTR(x) (&((x)->stringBuffer.bytes.ptr[(x)->stringBuffer.bytes.length]))


static void jk_managedBuffer_release(JKManagedBuffer *managedBuffer);
static void jk_managedBuffer_setToStackBuffer(JKManagedBuffer *managedBuffer, unsigned char *ptr, size_t length);
static unsigned char *jk_managedBuffer_resize(JKManagedBuffer *managedBuffer, size_t newSize);
static void jk_objectStack_release(JKObjectStack *objectStack);
static void jk_objectStack_setToStackBuffer(JKObjectStack *objectStack, void **objects, void **keys, size_t count);
static int  jk_objectStack_resize(JKObjectStack *objectStack, size_t newCount);

static void   jk_error(JKParseState *parseState, NSString *format, ...);
static int    jk_parse_string(JKParseState *parseState);
static int    jk_parse_number(JKParseState *parseState);
static size_t jk_parse_is_newline(JKParseState *parseState, const unsigned char *atCharacterPtr);
JK_STATIC_INLINE void jk_parse_skip_whitespace(JKParseState *parseState);
static int    jk_parse_next_token(JKParseState *parseState);
static void   jk_set_parsed_token(JKParseState *parseState, const unsigned char *ptr, size_t length, JKTokenType type, size_t advanceBy);
static void   jk_error_parse_accept_or3(JKParseState *parseState, int state, NSString *or1String, NSString *or2String, NSString *or3String);
static void  *jk_parse_dictionary(JKParseState *parseState);
static void  *jk_parse_array(JKParseState *parseState);
static void  *jk_object_for_token(JKParseState *parseState);
static void  *jk_cachedObjects(JKParseState *parseState);
JK_STATIC_INLINE void jk_cache_age(JKParseState *parseState);
JK_STATIC_INLINE void jk_set_parsed_token(JKParseState *parseState, const unsigned char *ptr, size_t length, JKTokenType type, size_t advanceBy);


JK_STATIC_INLINE size_t jk_min(size_t a, size_t b);
JK_STATIC_INLINE size_t jk_max(size_t a, size_t b);
JK_STATIC_INLINE JKHash calculateHash(JKHash currentHash, unsigned char c);
JK_STATIC_INLINE JKHash calculateNumberHash(JKHash currentHash, unsigned char c);



JK_STATIC_INLINE size_t jk_min(size_t a, size_t b) { return((a < b) ? a : b); }
JK_STATIC_INLINE size_t jk_max(size_t a, size_t b) { return((a > b) ? a : b); }

JK_STATIC_INLINE JKHash calculateHash(JKHash currentHash, unsigned char c) { return(((currentHash << 5) + currentHash) + c); }
JK_STATIC_INLINE JKHash calculateNumberHash(JKHash currentHash, unsigned char c) {
  uint64_t newHash = (currentHash ^ (0xa5a5a5c5ULL * calculateHash(currentHash, c)));
  newHash ^= newHash >> 29;
  newHash += newHash << 16;
  newHash ^= newHash >> 21;
  newHash += newHash << 32;
  return((JKHash)newHash);
}

static void jk_error(JKParseState *parseState, NSString *format, ...) {
  NSCParameterAssert((parseState != NULL) && (format != NULL));

  va_list varArgsList;
  va_start(varArgsList, format);
  NSString *formatString = [[[NSString alloc] initWithFormat:format arguments:varArgsList] autorelease];
  va_end(varArgsList);

#if 0
  const unsigned char *lineStart      = parseState->stringBuffer.bytes.ptr + parseState->lineStartIndex;
  const unsigned char *lineEnd        = lineStart;
  const unsigned char *atCharacterPtr = NULL;

  for(atCharacterPtr = lineStart; atCharacterPtr <= JK_END_STRING_PTR(parseState); atCharacterPtr++) { lineEnd = atCharacterPtr; if(jk_parse_is_newline(parseState, atCharacterPtr)) { break; } }

  NSString *lineString = @"", *carretString = @"";
  if(lineStart <= JK_END_STRING_PTR(parseState)) {
    lineString   = [[[NSString alloc] initWithBytes:lineStart length:(lineEnd - lineStart) encoding:NSUTF8StringEncoding] autorelease];
    carretString = [NSString stringWithFormat:@"%*.*s^", (int)(parseState->atIndex - parseState->lineStartIndex), (int)(parseState->atIndex - parseState->lineStartIndex), " "];
  }
#endif

  if(parseState->error == NULL) {
    parseState->error = [NSError errorWithDomain:@"JKErrorDomain" code:-1L userInfo:
                                   [NSDictionary dictionaryWithObjectsAndKeys:
                                                                              formatString,                                             NSLocalizedDescriptionKey,
                                                                              [NSNumber numberWithUnsignedLong:parseState->atIndex],    @"JKAtIndexKey",
                                                                              [NSNumber numberWithUnsignedLong:parseState->lineNumber], @"JKLineNumberKey",
                                                 //lineString,   @"JKErrorLine0Key",
                                                 //carretString, @"JKErrorLine1Key",
                                                                              NULL]];
  }
}


static void jk_managedBuffer_release(JKManagedBuffer *managedBuffer) {
  if((managedBuffer->flags & JKManagedBufferMustFree)) {
    if(managedBuffer->bytes.ptr != NULL) { free(managedBuffer->bytes.ptr); managedBuffer->bytes.ptr = NULL; }
    managedBuffer->flags &= ~JKManagedBufferMustFree;
  }

  managedBuffer->bytes.ptr     = NULL;
  managedBuffer->bytes.length  = 0UL;
  managedBuffer->flags        &= ~JKManagedBufferLocationMask;
}

static void jk_managedBuffer_setToStackBuffer(JKManagedBuffer *managedBuffer, unsigned char *ptr, size_t length) {
  jk_managedBuffer_release(managedBuffer);
  managedBuffer->bytes.ptr     = ptr;
  managedBuffer->bytes.length  = length;
  managedBuffer->flags         = (managedBuffer->flags & ~JKManagedBufferLocationMask) | JKManagedBufferOnStack;
}

static unsigned char *jk_managedBuffer_resize(JKManagedBuffer *managedBuffer, size_t newSize) {
  size_t roundedUpNewSize = newSize;

  if(managedBuffer->roundSizeUpToMultipleOf > 0UL) { roundedUpNewSize = newSize + ((managedBuffer->roundSizeUpToMultipleOf - (newSize % managedBuffer->roundSizeUpToMultipleOf)) % managedBuffer->roundSizeUpToMultipleOf); }

  if((roundedUpNewSize != managedBuffer->bytes.length) && (roundedUpNewSize > managedBuffer->bytes.length)) {
    if((managedBuffer->flags & JKManagedBufferLocationMask) == JKManagedBufferOnStack) {
      NSCParameterAssert((managedBuffer->flags & JKManagedBufferMustFree) == 0);
      unsigned char *newBuffer = NULL, *oldBuffer = managedBuffer->bytes.ptr;
      
      if((newBuffer = (unsigned char *)malloc(roundedUpNewSize)) == NULL) { return(NULL); }
      memcpy(newBuffer, oldBuffer, jk_min(managedBuffer->bytes.length, roundedUpNewSize));
      managedBuffer->flags        = (managedBuffer->flags & ~JKManagedBufferLocationMask) | (JKManagedBufferOnHeap | JKManagedBufferMustFree);
      managedBuffer->bytes.ptr    = newBuffer;
      managedBuffer->bytes.length = roundedUpNewSize;
    } else {
      NSCParameterAssert(((managedBuffer->flags & JKManagedBufferMustFree) != 0) && ((managedBuffer->flags & JKManagedBufferLocationMask) == JKManagedBufferOnHeap));
      if((managedBuffer->bytes.ptr = (unsigned char *)reallocf(managedBuffer->bytes.ptr, roundedUpNewSize)) == NULL) { return(NULL); }
      managedBuffer->bytes.length = roundedUpNewSize;
    }
  }

  return(managedBuffer->bytes.ptr);
}



static void jk_objectStack_release(JKObjectStack *objectStack) {
  NSCParameterAssert(objectStack != NULL);

  NSCParameterAssert(objectStack->index <= objectStack->count);
  size_t atIndex = 0UL;
  for(atIndex = 0UL; atIndex < objectStack->index; atIndex++) {
    if(objectStack->objects[atIndex] != NULL) { CFRelease(objectStack->objects[atIndex]); objectStack->objects[atIndex] = NULL; }
    if(objectStack->keys[atIndex]    != NULL) { CFRelease(objectStack->keys[atIndex]);    objectStack->keys[atIndex]    = NULL; }
  }
  objectStack->index = 0UL;

  if(objectStack->flags & JKObjectStackMustFree) {
    NSCParameterAssert((objectStack->flags & JKObjectStackLocationMask) == JKObjectStackOnHeap);
    if(objectStack->objects != NULL) { free(objectStack->objects); objectStack->objects = NULL; }
    if(objectStack->keys    != NULL) { free(objectStack->keys);    objectStack->keys    = NULL; }
    objectStack->flags &= ~JKObjectStackMustFree;
  }

  objectStack->objects  = NULL;
  objectStack->keys     = NULL;
  objectStack->count    = 0UL;
  objectStack->flags   &= ~JKObjectStackLocationMask;
}

static void jk_objectStack_setToStackBuffer(JKObjectStack *objectStack, void **objects, void **keys, size_t count) {
  NSCParameterAssert((objectStack != NULL) && (objects != NULL) && (keys != NULL) && (count > 0UL));
  jk_objectStack_release(objectStack);
  objectStack->objects = objects;
  objectStack->keys    = keys;
  objectStack->count   = count;
  objectStack->flags   = (objectStack->flags & ~JKObjectStackLocationMask) | JKObjectStackOnStack;
#ifndef NS_BLOCK_ASSERTIONS
  size_t idx;
  for(idx = 0UL; idx < objectStack->count; idx++) { objectStack->objects[idx] = NULL; objectStack->keys[idx] = NULL; }
#endif
}

static int jk_objectStack_resize(JKObjectStack *objectStack, size_t newCount) {
  size_t roundedUpNewCount = newCount;

  if(objectStack->roundSizeUpToMultipleOf > 0UL) { roundedUpNewCount = newCount + ((objectStack->roundSizeUpToMultipleOf - (newCount % objectStack->roundSizeUpToMultipleOf)) % objectStack->roundSizeUpToMultipleOf); }

  if((roundedUpNewCount != objectStack->count) && (roundedUpNewCount > objectStack->count)) {
    if((objectStack->flags & JKObjectStackLocationMask) == JKObjectStackOnStack) {
      NSCParameterAssert((objectStack->flags & JKObjectStackMustFree) == 0);
      void **newObjects = NULL, **newKeys = NULL;
      
      if((newObjects = (void **)calloc(1, roundedUpNewCount * sizeof(void *))) == NULL) { return(1); }
      memcpy(newObjects, objectStack->objects, jk_min(objectStack->count, roundedUpNewCount) * sizeof(void *));
      if((newKeys    = (void **)calloc(1, roundedUpNewCount * sizeof(void *))) == NULL) { free(newObjects); return(1); }
      memcpy(newKeys,    objectStack->keys,    jk_min(objectStack->count, roundedUpNewCount) * sizeof(void *));

      objectStack->flags   = (objectStack->flags & ~JKObjectStackLocationMask) | (JKObjectStackOnHeap | JKObjectStackMustFree);
      objectStack->objects = newObjects;
      objectStack->keys    = newKeys;
      objectStack->count   = roundedUpNewCount;
    } else {
      NSCParameterAssert(((objectStack->flags & JKObjectStackMustFree) != 0) && ((objectStack->flags & JKObjectStackLocationMask) == JKObjectStackOnHeap));
      void **newObjects = NULL, **newKeys = NULL;
      if((newObjects = (void **)realloc(objectStack->objects, roundedUpNewCount * sizeof(void *))) != NULL) { objectStack->objects = newObjects; } else { return(1); }
      if((newKeys    = (void **)realloc(objectStack->keys,    roundedUpNewCount * sizeof(void *))) != NULL) { objectStack->keys    = newKeys;    } else { return(1); }
#ifndef NS_BLOCK_ASSERTIONS
      size_t idx;
      for(idx = objectStack->count; idx < roundedUpNewCount; idx++) { objectStack->objects[idx] = NULL; objectStack->keys[idx] = NULL; }
#endif
      objectStack->count = roundedUpNewCount;
    }
  }

  return(0);
}


JK_STATIC_INLINE ConversionResult isValidCodePoint(UTF32 *u32CodePoint) {
  ConversionResult result = conversionOK;
  UTF32            ch     = *u32CodePoint;

  if((ch >= UNI_SUR_HIGH_START) && (JK_EXPECTED(ch <= UNI_SUR_LOW_END, 1u)))                                                                           { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }
  if((ch >= 0xFDD0UL) && ((JK_EXPECTED(ch <= 0xFDEFUL, 0U)) || JK_EXPECTED(((ch & 0xFFFEUL) == 0xFFFEUL), 0U)) && (JK_EXPECTED(ch <= 0x10FFFFUL, 1U))) { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }
  if(JK_EXPECTED(ch == 0UL, 0U))                                                                                                                       { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }

 finished:
  *u32CodePoint = ch;
  return(result);
}


static int isLegalUTF8(const UTF8 *source, size_t length) {
  const UTF8 *srcptr = source + length;
  UTF8 a;

  switch(length) {
    default: return(0); // Everything else falls through when "true"...
    case 4: if(JK_EXPECTED(((a = (*--srcptr)) < 0x80) || (a > 0xBF), 0U)) { return(0); }
    case 3: if(JK_EXPECTED(((a = (*--srcptr)) < 0x80) || (a > 0xBF), 0U)) { return(0); }
    case 2: if(JK_EXPECTED( (a = (*--srcptr)) > 0xBF               , 0U)) { return(0); }
      
      switch(*source) { // no fall-through in this inner switch
        case 0xE0: if(JK_EXPECTED(a < 0xA0, 0U)) { return(0); } break;
        case 0xED: if(JK_EXPECTED(a > 0x9F, 0U)) { return(0); } break;
        case 0xF0: if(JK_EXPECTED(a < 0x90, 0U)) { return(0); } break;
        case 0xF4: if(JK_EXPECTED(a > 0x8F, 0U)) { return(0); } break;
        default:   if(JK_EXPECTED(a < 0x80, 0U)) { return(0); }
      }
      
    case 1: if(JK_EXPECTED((JK_EXPECTED(*source < 0xC2, 0U)) && JK_EXPECTED(*source >= 0x80, 1U), 0U)) { return(0); }
  }

  if(JK_EXPECTED(*source > 0xF4, 0U)) { return(0); }

  return(1);
}

static ConversionResult ConvertSingleCodePointInUTF8(const UTF8 *sourceStart, const UTF8 *sourceEnd, UTF8 const **nextUTF8, UTF32 *convertedUTF32) {
  ConversionResult result = conversionOK;
  const UTF8 *source = sourceStart;
  UTF32 ch = 0UL;

#if !defined(JK_FAST_TRAILING_BYTES)
  unsigned short extraBytesToRead = trailingBytesForUTF8[*source];
#else
  unsigned short extraBytesToRead = __builtin_clz(((*source)^0xff) << 25);
#endif

  if(JK_EXPECTED((source + extraBytesToRead + 1) > sourceEnd, 0U) || JK_EXPECTED(!isLegalUTF8(source, extraBytesToRead + 1), 0U)) {
    source++;
    while((source < sourceEnd) && (((*source) & 0xc0) == 0x80) && ((source - sourceStart) < (extraBytesToRead + 1))) { source++; } 
    NSCParameterAssert(source <= sourceEnd);
    result = ((source + extraBytesToRead + 1) > sourceEnd) ? sourceExhausted : sourceIllegal;
    ch = UNI_REPLACEMENT_CHAR;
    goto finished;
  }

  switch(extraBytesToRead) { // The cases all fall through.
    case 5: ch += *source++; ch <<= 6;
    case 4: ch += *source++; ch <<= 6;
    case 3: ch += *source++; ch <<= 6;
    case 2: ch += *source++; ch <<= 6;
    case 1: ch += *source++; ch <<= 6;
    case 0: ch += *source++;
  }
  ch -= offsetsFromUTF8[extraBytesToRead];

  result = isValidCodePoint(&ch);
  
 finished:
  *nextUTF8       = source;
  *convertedUTF32 = ch;
  
  return(result);
}


static ConversionResult ConvertUTF32toUTF8 (UTF32 u32CodePoint, UTF8 **targetStart, UTF8 *targetEnd) {
  const UTF32       byteMask     = 0xBF, byteMark = 0x80;
  ConversionResult  result       = conversionOK;
  UTF8             *target       = *targetStart;
  UTF32             ch           = u32CodePoint;
  unsigned short    bytesToWrite = 0;

  result = isValidCodePoint(&ch);

  // Figure out how many bytes the result will require. Turn any illegally large UTF32 things (> Plane 17) into replacement chars.
       if(ch < (UTF32)0x80)          { bytesToWrite = 1; }
  else if(ch < (UTF32)0x800)         { bytesToWrite = 2; }
  else if(ch < (UTF32)0x10000)       { bytesToWrite = 3; }
  else if(ch <= UNI_MAX_LEGAL_UTF32) { bytesToWrite = 4; }
  else {                               bytesToWrite = 3; ch = UNI_REPLACEMENT_CHAR; result = sourceIllegal; }
        
  target += bytesToWrite;
  if (target > targetEnd) { target -= bytesToWrite; result = targetExhausted; goto finished; }

  switch (bytesToWrite) { // note: everything falls through.
    case 4: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 3: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 2: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 1: *--target = (UTF8) (ch | firstByteMark[bytesToWrite]);
  }

  target += bytesToWrite;

 finished:
  *targetStart = target;
  return(result);
}

JK_STATIC_INLINE int jk_string_add_unicodeCodePoint(JKParseState *parseState, uint32_t unicodeCodePoint, size_t *tokenBufferIdx, JKHash *stringHash) {
  UTF8             *u8s = &parseState->token.tokenBuffer.bytes.ptr[*tokenBufferIdx];
  ConversionResult  result;

  if((result = ConvertUTF32toUTF8(unicodeCodePoint, &u8s, (parseState->token.tokenBuffer.bytes.ptr + parseState->token.tokenBuffer.bytes.length))) != conversionOK) { if(result == targetExhausted) { return(1); } }
  size_t utf8len = u8s - &parseState->token.tokenBuffer.bytes.ptr[*tokenBufferIdx], nextIdx = (*tokenBufferIdx) + utf8len;
  
  while(*tokenBufferIdx < nextIdx) { *stringHash = calculateHash(*stringHash, parseState->token.tokenBuffer.bytes.ptr[(*tokenBufferIdx)++]); }

  return(0);
}


static int jk_parse_string(JKParseState *parseState) {
  const unsigned char *stringStart       = JK_AT_STRING_PTR(parseState) + 1;
  const unsigned char *endOfBuffer       = JK_END_STRING_PTR(parseState);
  const unsigned char *atStringCharacter = stringStart;
  unsigned char       *tokenBuffer       = parseState->token.tokenBuffer.bytes.ptr;
  size_t               tokenStartIndex   = parseState->atIndex;
  size_t               tokenBufferIdx = 0UL;

  int      onlySimpleString        = 1,  stringState     = JSONStringStateStart;
  uint16_t escapedUnicode1         = 0U, escapedUnicode2 = 0U;
  uint32_t escapedUnicodeCodePoint = 0U;
  JKHash   stringHash              = JK_HASH_INIT;

  while(1) {
    unsigned long currentChar;

    if(JK_EXPECTED(atStringCharacter == endOfBuffer, 0U)) { /* XXX Add error message */ stringState = JSONStringStateError; goto finishedParsing; }
    
    if(JK_EXPECTED((currentChar = *atStringCharacter++) >= 0x80UL, 0U)) {
      const unsigned char *nextValidCharacter = NULL;
      UTF32                u32ch              = 0UL;
      ConversionResult     result;

      if(JK_EXPECTED((result = ConvertSingleCodePointInUTF8(atStringCharacter - 1, endOfBuffer, (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK, 0L)) { goto switchToSlowPath; }
      stringHash = calculateHash(stringHash, currentChar);
      while(atStringCharacter < nextValidCharacter) { stringHash = calculateHash(stringHash, *atStringCharacter++); }
      continue;
    } else {
      if(JK_EXPECTED(currentChar == (unsigned long)'"',  0U)) { stringState = JSONStringStateFinished; goto finishedParsing; }

      if(JK_EXPECTED(currentChar == (unsigned long)'\\', 0U)) {
      switchToSlowPath:
        onlySimpleString = 0;
        stringState      = JSONStringStateParsing;
        tokenBufferIdx   = (atStringCharacter - stringStart) - 1L;
        if(JK_EXPECTED((tokenBufferIdx + 16UL) > parseState->token.tokenBuffer.bytes.length, 0U)) { if((tokenBuffer = jk_managedBuffer_resize(&parseState->token.tokenBuffer, tokenBufferIdx + 1024UL)) == NULL) { jk_error(parseState, @"Internal error: Unable to resize temporary buffer."); stringState = JSONStringStateError; goto finishedParsing; } }
        memcpy(tokenBuffer, stringStart, tokenBufferIdx);
        goto slowMatch;
      }

      if(JK_EXPECTED(currentChar < 0x20UL, 0U)) { jk_error(parseState, @"Invalid character < 0x20 found in string: 0x%2.2x.", currentChar); stringState = JSONStringStateError; goto finishedParsing; }

      stringHash = calculateHash(stringHash, currentChar);
    }
  }

 slowMatch:

  for(atStringCharacter = (stringStart + ((atStringCharacter - stringStart) - 1L)); (atStringCharacter < endOfBuffer) && (tokenBufferIdx < parseState->token.tokenBuffer.bytes.length); atStringCharacter++) {
    if((tokenBufferIdx + 16UL) > parseState->token.tokenBuffer.bytes.length) { if((tokenBuffer = jk_managedBuffer_resize(&parseState->token.tokenBuffer, tokenBufferIdx + 1024UL)) == NULL) { jk_error(parseState, @"Internal error: Unable to resize temporary buffer."); stringState = JSONStringStateError; goto finishedParsing; } }

    NSCParameterAssert(tokenBufferIdx < parseState->token.tokenBuffer.bytes.length);

    unsigned long currentChar = (*atStringCharacter), escapedChar;

    if(JK_EXPECTED(stringState == JSONStringStateParsing, 1U)) {
      if(JK_EXPECTED(currentChar < (unsigned long)0x80, 1U)) {
        if(JK_EXPECTED(currentChar == (unsigned long)'"',  0U)) { stringState = JSONStringStateFinished; atStringCharacter++; goto finishedParsing; }
        if(JK_EXPECTED(currentChar == (unsigned long)'\\', 0U)) { stringState = JSONStringStateEscape; continue; }
        stringHash = calculateHash(stringHash, currentChar);
        tokenBuffer[tokenBufferIdx++] = currentChar;
        continue;
      }

      if(JK_EXPECTED(currentChar >= 0x80UL, 1U)) {
        const unsigned char *nextValidCharacter = NULL;
        UTF32                u32ch              = 0U;
        ConversionResult     result;

        if(JK_EXPECTED((result = ConvertSingleCodePointInUTF8(atStringCharacter, endOfBuffer, (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK, 0U)) {
          if((result == sourceIllegal) && ((parseState->parseOptionFlags & JKParseOptionLooseUnicode) == 0)) { jk_error(parseState, @"Illegal UTF8 sequence found in \"\" string.");                                stringState = JSONStringStateError; goto finishedParsing; }
          if(result == sourceExhausted)                                                                      { jk_error(parseState, @"End of buffer reached while parsing \"\" string. line: %ld", (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; }
          if(jk_string_add_unicodeCodePoint(parseState, u32ch, &tokenBufferIdx, &stringHash))                { jk_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer.");     stringState = JSONStringStateError; goto finishedParsing; }
          atStringCharacter = nextValidCharacter - 1;
          continue;
        } else {
          while(atStringCharacter < nextValidCharacter) { tokenBuffer[tokenBufferIdx++] = *atStringCharacter; stringHash = calculateHash(stringHash, *atStringCharacter++); }
          atStringCharacter--;
          continue;
        }
      }

      if(JK_EXPECTED(currentChar < 0x20UL, 0U)) { jk_error(parseState, @"Invalid character < 0x20 found in string: 0x%2.2x.", currentChar); stringState = JSONStringStateError; goto finishedParsing; }

    } else {
      int isSurrogate = 1;

      switch(stringState) {
        case JSONStringStateEscape:
          switch(currentChar) {
            case 'u': escapedUnicode1 = 0U; escapedUnicode2 = 0U; escapedUnicodeCodePoint = 0U; stringState = JSONStringStateEscapedUnicode1; break;

            case 'b':  escapedChar = '\b'; goto parsedEscapedChar;
            case 'f':  escapedChar = '\f'; goto parsedEscapedChar;
            case 'n':  escapedChar = '\n'; goto parsedEscapedChar;
            case 'r':  escapedChar = '\r'; goto parsedEscapedChar;
            case 't':  escapedChar = '\t'; goto parsedEscapedChar;
            case '\\': escapedChar = '\\'; goto parsedEscapedChar;
            case '/':  escapedChar = '/';  goto parsedEscapedChar;
            case '"':  escapedChar = '"';  goto parsedEscapedChar;
              
            parsedEscapedChar:
              stringState = JSONStringStateParsing;
              stringHash  = calculateHash(stringHash, escapedChar);
              tokenBuffer[tokenBufferIdx++] = escapedChar;
              break;
              
            default: jk_error(parseState, @"Invalid escape sequence found in \"\" string."); stringState = JSONStringStateError; goto finishedParsing; break;
          }
          break;

        case JSONStringStateEscapedUnicode1:
        case JSONStringStateEscapedUnicode2:
        case JSONStringStateEscapedUnicode3:
        case JSONStringStateEscapedUnicode4:           isSurrogate = 0;
        case JSONStringStateEscapedUnicodeSurrogate1:
        case JSONStringStateEscapedUnicodeSurrogate2:
        case JSONStringStateEscapedUnicodeSurrogate3:
        case JSONStringStateEscapedUnicodeSurrogate4:
          {
            uint16_t hexValue = 0U;

            switch(currentChar) {
              case '0' ... '9': hexValue =  currentChar - '0';        goto parsedHex;
              case 'a' ... 'f': hexValue = (currentChar - 'a') + 10U; goto parsedHex;
              case 'A' ... 'F': hexValue = (currentChar - 'A') + 10U; goto parsedHex;
                
              parsedHex:
              if(!isSurrogate) { escapedUnicode1 = (escapedUnicode1 << 4) | hexValue; } else { escapedUnicode2 = (escapedUnicode2 << 4) | hexValue; }
                
              if(stringState == JSONStringStateEscapedUnicode4) {
                if(((escapedUnicode1 >= 0xD800U) && (escapedUnicode1 < 0xE000U))) {
                  if((escapedUnicode1 >= 0xD800U) && (escapedUnicode1 < 0xDC00U)) { stringState = JSONStringStateEscapedNeedEscapeForSurrogate; }
                  else if((escapedUnicode1 >= 0xDC00U) && (escapedUnicode1 < 0xE000U)) { 
                    if((parseState->parseOptionFlags & JKParseOptionLooseUnicode)) { escapedUnicodeCodePoint = UNI_REPLACEMENT_CHAR; }
                    else { jk_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                  }
                }
                else { escapedUnicodeCodePoint = escapedUnicode1; }
              }

              if(stringState == JSONStringStateEscapedUnicodeSurrogate4) {
                if((escapedUnicode2 < 0xdc00) || (escapedUnicode2 >= 0xdfff)) {
                  if((parseState->parseOptionFlags & JKParseOptionLooseUnicode)) { escapedUnicodeCodePoint = UNI_REPLACEMENT_CHAR; }
                  else { jk_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                }
                else { escapedUnicodeCodePoint = ((escapedUnicode1 - 0xd800) * 0x400) + (escapedUnicode2 - 0xdc00) + 0x10000; }
              }
                
              if((stringState == JSONStringStateEscapedUnicode4) || (stringState == JSONStringStateEscapedUnicodeSurrogate4)) { 
                if((parseState->parseOptionFlags & JKParseOptionLooseUnicode) == 0) {
                  UTF32 cp = escapedUnicodeCodePoint;
                  if(isValidCodePoint(&cp) == sourceIllegal) { jk_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                }
                stringState = JSONStringStateParsing;
                if(jk_string_add_unicodeCodePoint(parseState, escapedUnicodeCodePoint, &tokenBufferIdx, &stringHash)) { jk_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer."); stringState = JSONStringStateError; goto finishedParsing; }
              }
              else if((stringState >= JSONStringStateEscapedUnicode1) && (stringState <= JSONStringStateEscapedUnicodeSurrogate4)) { stringState++; }
              break;

              default: jk_error(parseState, @"Unexpected character found in \\u Unicode escape sequence.  Found '%c', expected [0-9a-fA-F].", currentChar); stringState = JSONStringStateError; goto finishedParsing; break;
            }
          }
          break;

        case JSONStringStateEscapedNeedEscapeForSurrogate:
          if((currentChar == '\\')) { stringState = JSONStringStateEscapedNeedEscapedUForSurrogate; }
          //else                      { stringState = JSONStringStateParsing; atStringCharacter--; if(jk_string_add_unicodeCodePoint(parseState, UNI_REPLACEMENT_CHAR, &tokenBufferIdx, &stringHash)) { /* XXX Add error message */ stringState = JSONStringStateError; goto finishedParsing; } }
          else                   { jk_error(parseState, @"Required a second \\u Unicode escape sequence following a surrogate \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
          break;

        case JSONStringStateEscapedNeedEscapedUForSurrogate:
          if(currentChar == 'u') { stringState = JSONStringStateEscapedUnicodeSurrogate1; }
          //else                   { stringState = JSONStringStateParsing; atStringCharacter -= 2; if(jk_string_add_unicodeCodePoint(parseState, UNI_REPLACEMENT_CHAR, &tokenBufferIdx, &stringHash)) { /* XXX Add error message */ stringState = JSONStringStateError; goto finishedParsing; } }
          else                   { jk_error(parseState, @"Required a second \\u Unicode escape sequence following a surrogate \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
          break;

        default: jk_error(parseState, @"Internal error: Unknown stringState."); stringState = JSONStringStateError; goto finishedParsing; break;
      }
    }
  }

finishedParsing:

  if(stringState == JSONStringStateFinished) {
    NSCParameterAssert((parseState->stringBuffer.bytes.ptr + tokenStartIndex) <= atStringCharacter);

    parseState->token.tokenPtrRange.ptr    = parseState->stringBuffer.bytes.ptr + tokenStartIndex;
    parseState->token.tokenPtrRange.length = (atStringCharacter - parseState->token.tokenPtrRange.ptr);

    if(onlySimpleString) {
      NSCParameterAssert(((parseState->token.tokenPtrRange.ptr + 1) <= endOfBuffer) && (parseState->token.tokenPtrRange.length >= 2UL) && (((parseState->token.tokenPtrRange.ptr + 1) + (parseState->token.tokenPtrRange.length - 2)) <= endOfBuffer));
      parseState->token.value.ptrRange.ptr    = parseState->token.tokenPtrRange.ptr    + 1;
      parseState->token.value.ptrRange.length = parseState->token.tokenPtrRange.length - 2;
    } else {
      parseState->token.value.ptrRange.ptr    = parseState->token.tokenBuffer.bytes.ptr;
      parseState->token.value.ptrRange.length = tokenBufferIdx;
    }
    
    parseState->token.value.hash = stringHash;
    parseState->token.value.type = JKValueTypeString;
    parseState->atIndex          = (atStringCharacter - parseState->stringBuffer.bytes.ptr);
  }

  if(stringState != JSONStringStateFinished) { jk_error(parseState, @"Invalid string."); }
  return((stringState == JSONStringStateFinished) ? 0 : 1);
}

static int jk_parse_number(JKParseState *parseState) {
  const unsigned char *numberStart       = JK_AT_STRING_PTR(parseState);
  const unsigned char *endOfBuffer       = JK_END_STRING_PTR(parseState);
  const unsigned char *atNumberCharacter = NULL;
  int                  numberState       = JSONNumberStateWholeNumberStart, isFloatingPoint = 0, isNegative = 0, backup = 0;
  size_t               startingIndex     = parseState->atIndex;

  for(atNumberCharacter = numberStart; (JK_EXPECTED(atNumberCharacter < endOfBuffer, 1U)) && (JK_EXPECTED(!((numberState == JSONNumberStateFinished) || (numberState == JSONNumberStateError)), 1U)); atNumberCharacter++) {
    unsigned long currentChar = (unsigned long)(*atNumberCharacter);

    switch(numberState) {
      case JSONNumberStateWholeNumberStart: if   (currentChar == '-')                                                                              { numberState = JSONNumberStateWholeNumberMinus;      isNegative      = 1; break; }
      case JSONNumberStateWholeNumberMinus: if   (currentChar == '0')                                                                              { numberState = JSONNumberStateWholeNumberZero;                            break; }
                                       else if(  (currentChar >= '1') && (currentChar <= '9'))                                                     { numberState = JSONNumberStateWholeNumber;                                break; }
                                       else                                                     { /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break; }
      case JSONNumberStateExponentStart:    if(  (currentChar == '+') || (currentChar == '-'))                                                     { numberState = JSONNumberStateExponentPlusMinus;                          break; }
      case JSONNumberStateFractionalNumberStart:
      case JSONNumberStateExponentPlusMinus:if(!((currentChar >= '0') && (currentChar <= '9'))) { /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break; }
                                       else {                                              if(numberState == JSONNumberStateFractionalNumberStart) { numberState = JSONNumberStateFractionalNumber; }
                                                                                           else                                                    { numberState = JSONNumberStateExponent;         }                         break; }
      case JSONNumberStateWholeNumberZero:
      case JSONNumberStateWholeNumber:      if   (currentChar == '.')                                                                              { numberState = JSONNumberStateFractionalNumberStart; isFloatingPoint = 1; break; }
      case JSONNumberStateFractionalNumber: if(  (currentChar == 'e') || (currentChar == 'E'))                                                     { numberState = JSONNumberStateExponentStart;         isFloatingPoint = 1; break; }
      case JSONNumberStateExponent:         if(!((currentChar >= '0') && (currentChar <= '9')) || (numberState == JSONNumberStateWholeNumberZero)) { numberState = JSONNumberStateFinished;              backup          = 1; break; }
        break;
      default:                                                                                    /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break;
    }
  }

  parseState->token.tokenPtrRange.ptr    = parseState->stringBuffer.bytes.ptr + startingIndex;
  parseState->token.tokenPtrRange.length = (atNumberCharacter - parseState->token.tokenPtrRange.ptr) - backup;
  parseState->atIndex                    = (parseState->token.tokenPtrRange.ptr + parseState->token.tokenPtrRange.length) - parseState->stringBuffer.bytes.ptr;

  if(numberState == JSONNumberStateFinished) {
    unsigned char  numberTempBuf[parseState->token.tokenPtrRange.length + 4UL];
    unsigned char *endOfNumber = NULL;

    memcpy(numberTempBuf, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length);
    numberTempBuf[parseState->token.tokenPtrRange.length] = 0;

    errno = 0;

    if(isFloatingPoint) {
      parseState->token.value.number.doubleValue = strtod((const char *)numberTempBuf, (char **)&endOfNumber);
      parseState->token.value.type               = JKValueTypeDouble;
      parseState->token.value.ptrRange.ptr       = (const unsigned char *)&parseState->token.value.number.doubleValue;
      parseState->token.value.ptrRange.length    = sizeof(double);
      parseState->token.value.hash               = (JK_HASH_INIT + parseState->token.value.type);
    } else {
      if(isNegative) {
        parseState->token.value.number.longLongValue = strtoll((const char *)numberTempBuf, (char **)&endOfNumber, 10);
        parseState->token.value.type                 = JKValueTypeLongLong;
        parseState->token.value.ptrRange.ptr         = (const unsigned char *)&parseState->token.value.number.longLongValue;
        parseState->token.value.ptrRange.length      = sizeof(long long);
        parseState->token.value.hash                 = (JK_HASH_INIT + parseState->token.value.type) + parseState->token.value.number.longLongValue;
      } else {
        parseState->token.value.number.unsignedLongLongValue = strtoull((const char *)numberTempBuf, (char **)&endOfNumber, 10);
        parseState->token.value.type                         = JKValueTypeUnsignedLongLong;
        parseState->token.value.ptrRange.ptr                 = (const unsigned char *)&parseState->token.value.number.unsignedLongLongValue;
        parseState->token.value.ptrRange.length              = sizeof(unsigned long long);
        parseState->token.value.hash                         = (JK_HASH_INIT + parseState->token.value.type) + parseState->token.value.number.unsignedLongLongValue;
      }
    }

    if(errno != 0) {
      numberState = JSONNumberStateError;
      if(errno == ERANGE) {
        switch(parseState->token.value.type) {
          case JKValueTypeDouble:           jk_error(parseState, @"The value '%s' could not be represented as a 'double' due to %s.",           numberTempBuf, (parseState->token.value.number.doubleValue == 0.0) ? "underflow" : "overflow"); break;
          case JKValueTypeLongLong:         jk_error(parseState, @"The value '%s' exceeded the minimum value that could be represented: %lld.", numberTempBuf, parseState->token.value.number.longLongValue); break;
          case JKValueTypeUnsignedLongLong: jk_error(parseState, @"The value '%s' exceeded the maximum value that could be represented: %llu.", numberTempBuf, parseState->token.value.number.unsignedLongLongValue); break;
          default: jk_error(parseState, @"Internal error: Unnkown token value type."); break;
        }
      }
    }
    if(endOfNumber != &numberTempBuf[parseState->token.tokenPtrRange.length]) { numberState = JSONNumberStateError; jk_error(parseState, @"The conversion function did not consume all of the number tokens characters."); }

    size_t hashIndex = 0UL;
    for(hashIndex = 0UL; hashIndex < parseState->token.value.ptrRange.length; hashIndex++) { parseState->token.value.hash = calculateNumberHash(parseState->token.value.hash, parseState->token.value.ptrRange.ptr[hashIndex]); }
  }

  if(numberState != JSONNumberStateFinished) { jk_error(parseState, @"Invalid number."); }
  return((numberState == JSONNumberStateFinished) ? 0 : 1);
}

JK_STATIC_INLINE void jk_set_parsed_token(JKParseState *parseState, const unsigned char *ptr, size_t length, JKTokenType type, size_t advanceBy) {
  parseState->token.tokenPtrRange.ptr     = ptr;
  parseState->token.tokenPtrRange.length  = length;
  parseState->token.type                  = type;
  parseState->atIndex                    += advanceBy;
}

static size_t jk_parse_is_newline(JKParseState *parseState, const unsigned char *atCharacterPtr) {
  NSCParameterAssert((parseState != NULL) && (atCharacterPtr != NULL) && (atCharacterPtr >= parseState->stringBuffer.bytes.ptr) && (atCharacterPtr <= JK_END_STRING_PTR(parseState)));
  const unsigned char *endOfStringPtr = JK_END_STRING_PTR(parseState);

  if(JK_EXPECTED(atCharacterPtr > endOfStringPtr, 0U)) { return(0UL); }

  if(JK_EXPECTED((*(atCharacterPtr + 0)) == '\n', 0U)) { return(1UL); }
  if(JK_EXPECTED((*(atCharacterPtr + 0)) == '\r', 0U)) { if((JK_EXPECTED((atCharacterPtr + 1) <= endOfStringPtr, 1U)) && ((*(atCharacterPtr + 1)) == '\n')) { return(2UL); } return(1UL); }
  if(parseState->parseOptionFlags & JKParseOptionUnicodeNewlines) {
    if((JK_EXPECTED((*(atCharacterPtr + 0)) == 0xc2, 0U)) && (((atCharacterPtr + 1) <= endOfStringPtr) && ((*(atCharacterPtr + 1)) == 0x85))) { return(2UL); }
    if((JK_EXPECTED((*(atCharacterPtr + 0)) == 0xe2, 0U)) && (((atCharacterPtr + 1) <= endOfStringPtr) && ((*(atCharacterPtr + 1)) == 0x80)) && (((atCharacterPtr + 2) <= endOfStringPtr) && (((*(atCharacterPtr + 2)) == 0xa8) || ((*(atCharacterPtr + 2)) == 0xa9)))) { return(3UL); }
  }

  return(0UL);
}

static int jk_parse_skip_newline(JKParseState *parseState) {
  size_t newlineAdvanceAtIndex = 0UL;
  if(JK_EXPECTED((newlineAdvanceAtIndex = jk_parse_is_newline(parseState, JK_AT_STRING_PTR(parseState))) > 0UL, 0U)) { parseState->lineNumber++; parseState->atIndex += (newlineAdvanceAtIndex - 1UL); parseState->lineStartIndex = parseState->atIndex + 1UL; return(1); }
  return(0);
}

JK_STATIC_INLINE void jk_parse_skip_whitespace(JKParseState *parseState) {
  NSCParameterAssert((parseState != NULL));
  const unsigned char *atCharacterPtr   = NULL;
  const unsigned char *endOfStringPtr   = JK_END_STRING_PTR(parseState);

  for(atCharacterPtr = JK_AT_STRING_PTR(parseState); (JK_EXPECTED((atCharacterPtr = JK_AT_STRING_PTR(parseState)) <= endOfStringPtr, 1U)); parseState->atIndex++) {
    if(((*(atCharacterPtr + 0)) == ' ') || ((*(atCharacterPtr + 0)) == '\t')) { continue; }
    if(jk_parse_skip_newline(parseState)) { continue; }
    if(parseState->parseOptionFlags & JKParseOptionComments) {
      if((JK_EXPECTED((*(atCharacterPtr + 0)) == '/', 0U)) && (JK_EXPECTED((atCharacterPtr + 1) <= endOfStringPtr, 1U))) {
        if((*(atCharacterPtr + 1)) == '/') {
          parseState->atIndex++;
          for(atCharacterPtr = JK_AT_STRING_PTR(parseState); (JK_EXPECTED((atCharacterPtr = JK_AT_STRING_PTR(parseState)) <= endOfStringPtr, 1U)); parseState->atIndex++) { if(jk_parse_skip_newline(parseState)) { break; } }
          continue;
        }
        if((*(atCharacterPtr + 1)) == '*') {
          parseState->atIndex++;
          for(atCharacterPtr = JK_AT_STRING_PTR(parseState); (JK_EXPECTED((atCharacterPtr = JK_AT_STRING_PTR(parseState)) <= endOfStringPtr, 1U)); parseState->atIndex++) {
            if(jk_parse_skip_newline(parseState)) { continue; }
            if(((*(atCharacterPtr + 0)) == '*') && (((atCharacterPtr + 1) <= endOfStringPtr) && ((*(atCharacterPtr + 1)) == '/'))) { parseState->atIndex++; break; }
          }
          continue;
        }
      }
    }
    break;
  }
}

static int jk_parse_next_token(JKParseState *parseState) {
  NSCParameterAssert((parseState != NULL));
  const unsigned char *atCharacterPtr   = NULL;
  const unsigned char *endOfStringPtr   = JK_END_STRING_PTR(parseState);
  unsigned char        currentCharacter = 0U;
  int                  stopParsing      = 0;

  parseState->prev_atIndex        = parseState->atIndex;
  parseState->prev_lineNumber     = parseState->lineNumber;
  parseState->prev_lineStartIndex = parseState->lineStartIndex;

  jk_parse_skip_whitespace(parseState);

  if((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED((atCharacterPtr = JK_AT_STRING_PTR(parseState)) <= endOfStringPtr, 1U))) {
    currentCharacter = *atCharacterPtr;

    switch(currentCharacter) {
      case '{': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeObjectBegin, 1UL); break;
      case '}': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeObjectEnd,   1UL); break;
      case '[': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeArrayBegin,  1UL); break;
      case ']': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeArrayEnd,    1UL); break;
      case ',': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeComma,       1UL); break;
      case ':': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeSeparator,   1UL); break;

      case 't': if(!((JK_EXPECTED((atCharacterPtr + 4UL) <= endOfStringPtr, 1U)) && (JK_EXPECTED(atCharacterPtr[1] == 'r', 1U)) && (JK_EXPECTED(atCharacterPtr[2] == 'u', 1U)) && (JK_EXPECTED(atCharacterPtr[3] == 'e', 1U))))                                                { stopParsing = 1; /* XXX Add error message */ } else { jk_set_parsed_token(parseState, atCharacterPtr, 4UL, JKTokenTypeTrue,  4UL); } break;
      case 'f': if(!((JK_EXPECTED((atCharacterPtr + 5UL) <= endOfStringPtr, 1U)) && (JK_EXPECTED(atCharacterPtr[1] == 'a', 1U)) && (JK_EXPECTED(atCharacterPtr[2] == 'l', 1U)) && (JK_EXPECTED(atCharacterPtr[3] == 's', 1U)) && (JK_EXPECTED(atCharacterPtr[4] == 'e', 1U)))) { stopParsing = 1; /* XXX Add error message */ } else { jk_set_parsed_token(parseState, atCharacterPtr, 5UL, JKTokenTypeFalse, 5UL); } break;
      case 'n': if(!((JK_EXPECTED((atCharacterPtr + 4UL) <= endOfStringPtr, 1U)) && (JK_EXPECTED(atCharacterPtr[1] == 'u', 1U)) && (JK_EXPECTED(atCharacterPtr[2] == 'l', 1U)) && (JK_EXPECTED(atCharacterPtr[3] == 'l', 1U))))                                                { stopParsing = 1; /* XXX Add error message */ } else { jk_set_parsed_token(parseState, atCharacterPtr, 4UL, JKTokenTypeNull,  4UL); } break;

      case '"': if(JK_EXPECTED((stopParsing = jk_parse_string(parseState)) == 0, 1U)) { jk_set_parsed_token(parseState, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length, JKTokenTypeString, 0UL); } break;

      case '-': // fall-thru
      case '0' ... '9': if(JK_EXPECTED((stopParsing = jk_parse_number(parseState)) == 0, 1U)) { jk_set_parsed_token(parseState, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length, JKTokenTypeNumber, 0UL); } break;

      default: stopParsing = 1; /* XXX Add error message */ break;
    }
  }

  if(JK_EXPECTED(stopParsing, 0U)) { jk_error(parseState, @"Unexpected token, wanted '{', '}', '[', ']', ',', ':', 'true', 'false', 'null', '\"STRING\"', 'NUMBER'."); }
  return(stopParsing);
}


JK_STATIC_INLINE void jk_cache_age(JKParseState *parseState) {
  parseState->cache.clockIdx                              = (parseState->cache.clockIdx + 19UL) & (parseState->cache.count - 1);
  parseState->cache.items[parseState->cache.clockIdx].age = (parseState->cache.items[parseState->cache.clockIdx].age >> 1);
}

static void *jk_cachedObjects(JKParseState *parseState) {
  unsigned long bucket = parseState->token.value.hash & (parseState->cache.count - 1), setBucket = 0UL, useableBucket = 0UL, x = 0UL;
  void *parsedAtom = NULL;

  jk_cache_age(parseState);

  if((parseState->token.value.type == JKValueTypeString) && (parseState->token.value.ptrRange.length == 0)) { return(@""); }

  for(x = 0UL; x < JK_CACHE_PROBES; x++) {
    if(JK_EXPECTED(parseState->cache.items[bucket].object == NULL, 0U)) { setBucket = 1UL; useableBucket = bucket; break; }

    if((JK_EXPECTED(parseState->cache.items[bucket].hash == parseState->token.value.hash, 1U)) && (JK_EXPECTED(parseState->cache.items[bucket].size == parseState->token.value.ptrRange.length, 1U)) && (JK_EXPECTED(parseState->cache.items[bucket].type == parseState->token.value.type, 1U)) && (JK_EXPECTED(parseState->cache.items[bucket].bytes != NULL, 1U)) && (JK_EXPECTED(strncmp((const char *)parseState->cache.items[bucket].bytes, (const char *)parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length) == 0, 1U))) {
      parseState->cache.items[bucket].age = (parseState->cache.items[bucket].age << 1) | 1;
      return((void *)CFRetain(parseState->cache.items[bucket].object));
    } else {
      if(JK_EXPECTED(setBucket == 0UL, 0U) && JK_EXPECTED(parseState->cache.items[bucket].age == 0, 0U)) { setBucket = 1UL; useableBucket = bucket; }
      if(JK_EXPECTED(setBucket == 0UL, 0U))                                                              { parseState->cache.items[bucket].age = (parseState->cache.items[bucket].age >> 1); jk_cache_age(parseState); }
      jk_cache_age(parseState);
      bucket = (parseState->token.value.hash + (parseState->token.value.ptrRange.length * (x + 1UL)) + (parseState->token.value.type * (x + 1UL)) + (3UL * (x + 1UL))) & (parseState->cache.count - 1);
    }
  }

  switch(parseState->token.value.type) {
    case JKValueTypeString:           parsedAtom = (void *)CFStringCreateWithBytes(NULL, parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length, kCFStringEncodingUTF8, 0); break;
    case JKValueTypeLongLong:         parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberLongLongType, &parseState->token.value.number.longLongValue);                                             break;
    case JKValueTypeUnsignedLongLong: parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberLongLongType, &parseState->token.value.number.unsignedLongLongValue);                                     break;
    case JKValueTypeDouble:           parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberDoubleType,   &parseState->token.value.number.doubleValue);                                               break;
    default: jk_error(parseState, @"Internal error: Unknown token value type. line #%ld", (long)__LINE__); break;
  }

  if(JK_EXPECTED(setBucket, 1U) && (JK_EXPECTED(parsedAtom != NULL, 1U))) {
    bucket = useableBucket;
    if(parseState->cache.items[bucket].object != NULL) { CFRelease(parseState->cache.items[bucket].object); parseState->cache.items[bucket].object = NULL; }

    if(JK_EXPECTED((parseState->cache.items[bucket].bytes = (unsigned char *)reallocf(parseState->cache.items[bucket].bytes, parseState->token.value.ptrRange.length + (parseState->token.value.type == JKValueTypeString ? 1UL : 0UL))) != NULL, 1U)) {
      memcpy(parseState->cache.items[bucket].bytes, parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length);
      if(parseState->token.value.type == JKValueTypeString) { parseState->cache.items[bucket].bytes[parseState->token.value.ptrRange.length] = 0; }
      parseState->cache.items[bucket].object = (void *)CFRetain(parsedAtom);
      parseState->cache.items[bucket].hash   = parseState->token.value.hash;
      parseState->cache.items[bucket].size   = parseState->token.value.ptrRange.length;
      parseState->cache.items[bucket].age    = JK_INIT_CACHE_AGE;
      parseState->cache.items[bucket].type   = parseState->token.value.type;
    }
  }

  return(parsedAtom);
}

static void *jk_object_for_token(JKParseState *parseState) {
  void *parsedAtom = NULL;

  switch(parseState->token.type) {
    case JKTokenTypeString:      parsedAtom = jk_cachedObjects(parseState);    break;
    case JKTokenTypeNumber:      parsedAtom = jk_cachedObjects(parseState);    break;
    case JKTokenTypeObjectBegin: parsedAtom = jk_parse_dictionary(parseState); break;
    case JKTokenTypeArrayBegin:  parsedAtom = jk_parse_array(parseState);      break;
    case JKTokenTypeTrue:        parsedAtom = (void *)kCFBooleanTrue;          break;
    case JKTokenTypeFalse:       parsedAtom = (void *)kCFBooleanFalse;         break;
    case JKTokenTypeNull:        parsedAtom = (void *)kCFNull;                 break;
    default: jk_error(parseState, @"Internal error: Unknown token type. line #%ld", (long)__LINE__); break;
  }

  return(parsedAtom);
}

static void jk_error_parse_accept_or3(JKParseState *parseState, int state, NSString *or1String, NSString *or2String, NSString *or3String) {
  NSString *acceptStrings[16];
  int acceptIdx = 0;
  if(state & JKParseAcceptValue) { acceptStrings[acceptIdx++] = or1String; }
  if(state & JKParseAcceptComma) { acceptStrings[acceptIdx++] = or2String; }
  if(state & JKParseAcceptEnd)   { acceptStrings[acceptIdx++] = or3String; }
       if(acceptIdx == 1) { jk_error(parseState, @"Expected %@, not '%*.*s'",           acceptStrings[0],                                     (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
  else if(acceptIdx == 2) { jk_error(parseState, @"Expected %@ or %@, not '%*.*s'",     acceptStrings[0], acceptStrings[1],                   (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
  else if(acceptIdx == 3) { jk_error(parseState, @"Expected %@, %@, or %@, not '%*.*s", acceptStrings[0], acceptStrings[1], acceptStrings[2], (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
}

static void *jk_parse_array(JKParseState *parseState) {
  size_t  startingObjectIndex = parseState->objectStack.index;
  int     arrayState          = JKParseAcceptValueOrEnd, stopParsing = 0;
  void   *parsedArray         = NULL;

  while(JK_EXPECTED((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED(parseState->atIndex < parseState->stringBuffer.bytes.length, 1U)), 1U)) {
    if(JK_EXPECTED(parseState->objectStack.index > (parseState->objectStack.count - 4), 0U)) { if(jk_objectStack_resize(&parseState->objectStack, parseState->objectStack.count + 128UL)) { jk_error(parseState, @"Internal error: [array] objectsIndex > %zu, resize failed?\n", (parseState->objectStack.count - 4)); break; } }

    if(JK_EXPECTED((stopParsing = jk_parse_next_token(parseState)) == 0, 1U)) {
      void *object = NULL;
#ifndef NS_BLOCK_ASSERTIONS
      parseState->objectStack.objects[parseState->objectStack.index] = NULL;
      parseState->objectStack.keys   [parseState->objectStack.index] = NULL;
#endif
      switch(parseState->token.type) {
        case JKTokenTypeNumber:
        case JKTokenTypeString:
        case JKTokenTypeTrue:
        case JKTokenTypeFalse:
        case JKTokenTypeNull:
        case JKTokenTypeArrayBegin:
        case JKTokenTypeObjectBegin:
          if(JK_EXPECTED((arrayState & JKParseAcceptValue)          == 0,    0U)) { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected value.");              stopParsing = 1; break; }
          if(JK_EXPECTED((object = jk_object_for_token(parseState)) == NULL, 0U)) {                              jk_error(parseState, @"Internal error: Object == NULL"); stopParsing = 1; break; } else { parseState->objectStack.objects[parseState->objectStack.index++] = object; arrayState = JKParseAcceptCommaOrEnd; }
          break;
        case JKTokenTypeArrayEnd: if(JK_EXPECTED(arrayState & JKParseAcceptEnd  , 1U)) { NSCParameterAssert(parseState->objectStack.index >= startingObjectIndex); parsedArray = (void *)CFArrayCreate(NULL, (const void **)&parseState->objectStack.objects[startingObjectIndex], parseState->objectStack.index - startingObjectIndex, &jk_transferOwnershipArrayCallBacks); } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected ']'."); } stopParsing = 1; break;
        case JKTokenTypeComma:    if(JK_EXPECTED(arrayState & JKParseAcceptComma, 1U)) { arrayState = JKParseAcceptValue; } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected ','."); stopParsing = 1; } break;
        default: parseState->errorIsPrev = 1; jk_error_parse_accept_or3(parseState, arrayState, @"a value", @"a comma", @"a ']'"); stopParsing = 1; break;
      }
    }
  }

  if(JK_EXPECTED(parsedArray == NULL, 0U)) { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { if(parseState->objectStack.objects[idx] != NULL) { CFRelease(parseState->objectStack.objects[idx]); parseState->objectStack.objects[idx] = NULL; } } }
#ifndef NS_BLOCK_ASSERTIONS
  else { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { parseState->objectStack.objects[idx] = NULL; parseState->objectStack.keys[idx] = NULL; } }
#endif

  parseState->objectStack.index = startingObjectIndex;
  return(parsedArray);
}


static void *jk_parse_dictionary(JKParseState *parseState) {
  size_t  startingObjectIndex = parseState->objectStack.index;
  int     dictState           = JKParseAcceptValueOrEnd, stopParsing = 0;
  void   *parsedDictionary    = NULL;

  while(JK_EXPECTED((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED(parseState->atIndex < parseState->stringBuffer.bytes.length, 1U)), 1U)) {
    if(JK_EXPECTED(parseState->objectStack.index > (parseState->objectStack.count - 4), 0U)) { if(jk_objectStack_resize(&parseState->objectStack, parseState->objectStack.count + 128UL)) { jk_error(parseState, @"Internal error: [dictionary] objectsIndex > %zu, resize failed?\n", (parseState->objectStack.count - 4)); break; } }

    size_t objectStackIndex = parseState->objectStack.index++;
    parseState->objectStack.keys[objectStackIndex]    = NULL;
    parseState->objectStack.objects[objectStackIndex] = NULL;
    void *key = NULL, *object = NULL;

    if(JK_EXPECTED((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED((stopParsing = jk_parse_next_token(parseState)) == 0, 1U)), 1U)) {
      switch(parseState->token.type) {
        case JKTokenTypeString:
          if(JK_EXPECTED((dictState & JKParseAcceptValue)        == 0,    0U)) { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected string.");           stopParsing = 1; break; }
          if(JK_EXPECTED((key = jk_object_for_token(parseState)) == NULL, 0U)) {                              jk_error(parseState, @"Internal error: Key == NULL."); stopParsing = 1; break; } else { parseState->objectStack.keys[objectStackIndex] = key; }
          break;

        case JKTokenTypeObjectEnd: if((JK_EXPECTED(dictState & JKParseAcceptEnd,   1U))) { NSCParameterAssert(parseState->objectStack.index >= startingObjectIndex); parsedDictionary = (void *)CFDictionaryCreate(NULL, (const void **)&parseState->objectStack.keys[startingObjectIndex], (const void **)&parseState->objectStack.objects[startingObjectIndex], (--parseState->objectStack.index) - startingObjectIndex, &jk_transferOwnershipDictionaryKeyCallBacks, &jk_transferOwnershipDictionaryValueCallBacks); } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected '}'."); } stopParsing = 1; break;
        case JKTokenTypeComma:     if((JK_EXPECTED(dictState & JKParseAcceptComma, 1U))) { dictState = JKParseAcceptValue; parseState->objectStack.index--; continue; } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected ','."); stopParsing = 1; } break;

        default: parseState->errorIsPrev = 1; jk_error_parse_accept_or3(parseState, dictState, @"a \"STRING\"", @"a comma", @"a '}'"); stopParsing = 1; break;
      }
    }

    if(JK_EXPECTED(stopParsing == 0, 1U)) {
      if(JK_EXPECTED((stopParsing = jk_parse_next_token(parseState)) == 0, 1U)) { if(JK_EXPECTED(parseState->token.type != JKTokenTypeSeparator, 0U)) { parseState->errorIsPrev = 1; jk_error(parseState, @"Expected ':'."); stopParsing = 1; } }
    }

    if((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED((stopParsing = jk_parse_next_token(parseState)) == 0, 1U))) {
      switch(parseState->token.type) {
        case JKTokenTypeNumber:
        case JKTokenTypeString:
        case JKTokenTypeTrue:
        case JKTokenTypeFalse:
        case JKTokenTypeNull:
        case JKTokenTypeArrayBegin:
        case JKTokenTypeObjectBegin:
          if(JK_EXPECTED((dictState & JKParseAcceptValue)           == 0,    0U)) { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected value.");               stopParsing = 1; break; }
          if(JK_EXPECTED((object = jk_object_for_token(parseState)) == NULL, 0U)) {                              jk_error(parseState, @"Internal error: Object == NULL."); stopParsing = 1; break; } else { parseState->objectStack.objects[objectStackIndex] = object; dictState = JKParseAcceptCommaOrEnd; }
          break;
        default: parseState->errorIsPrev = 1; jk_error_parse_accept_or3(parseState, dictState, @"a value", @"a comma", @"a '}'"); stopParsing = 1; break;
      }
    }
  }

  if(JK_EXPECTED(parsedDictionary == NULL, 0U)) { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { if(parseState->objectStack.keys[idx] != NULL) { CFRelease(parseState->objectStack.keys[idx]); parseState->objectStack.keys[idx] = NULL; } if(parseState->objectStack.objects[idx] != NULL) { CFRelease(parseState->objectStack.objects[idx]); parseState->objectStack.objects[idx] = NULL; } } }
#ifndef NS_BLOCK_ASSERTIONS
  else { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { parseState->objectStack.objects[idx] = NULL; parseState->objectStack.keys[idx] = NULL; } }
#endif

  parseState->objectStack.index = startingObjectIndex;
  return(parsedDictionary);
}

static id json_parse_it(JKParseState *parseState) {
  id  parsedObject = NULL;
  int stopParsing  = 0;

  while((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED(parseState->atIndex < parseState->stringBuffer.bytes.length, 1U))) {
    if((JK_EXPECTED(stopParsing == 0, 1U)) && (JK_EXPECTED((stopParsing = jk_parse_next_token(parseState)) == 0, 1U))) {
      switch(parseState->token.type) {
        case JKTokenTypeArrayBegin:
        case JKTokenTypeObjectBegin: parsedObject = [(id)jk_object_for_token(parseState) autorelease]; stopParsing = 1; break;
        default:                     jk_error(parseState, @"Expected either '[' or '{'.");             stopParsing = 1; break;
      }
    }
  }

  NSCParameterAssert(parseState->objectStack.index == 0);

  if((parsedObject == NULL) && (JK_AT_STRING_PTR(parseState) == JK_END_STRING_PTR(parseState))) { jk_error(parseState, @"Reached the end of the buffer."); }
  if(parsedObject == NULL) { jk_error(parseState, @"Unable to parse JSON."); }

  if((parsedObject != NULL) && (JK_AT_STRING_PTR(parseState) < JK_END_STRING_PTR(parseState))) {
    jk_parse_skip_whitespace(parseState);
    if((parsedObject != NULL) && ((parseState->parseOptionFlags & JKParseOptionPermitTextAfterValidJSON) == 0) && (JK_AT_STRING_PTR(parseState) < JK_END_STRING_PTR(parseState))) {
      jk_error(parseState, @"A valid JSON object was parsed but there were additional non-white-space characters remaining.");
      parsedObject = NULL;
    }
  }

  return(parsedObject);
}

@implementation JSONDecoder

+ (id)decoder
{
  return([self decoderWithParseOptions:JKParseOptionStrict]);
}

+ (id)decoderWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  return([[[self alloc] initWithParseOptions:parseOptionFlags] autorelease]);
}

- (id)init
{
  return([self initWithParseOptions:JKParseOptionStrict]);
}

- (id)initWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  if((self = [super init]) == NULL) { return(NULL); }

  if(parseOptionFlags & ~JKParseOptionValidFlags) { [self autorelease]; [NSException raise:NSInvalidArgumentException format:@"Invalid parse options."]; }
  parseState.parseOptionFlags = parseOptionFlags;

  parseState.token.tokenBuffer.roundSizeUpToMultipleOf = 4096UL;
  parseState.objectStack.roundSizeUpToMultipleOf       = 2048UL;

  parseState.cache.count = JK_CACHE_SLOTS;
  if((parseState.cache.items = (JKTokenCacheItem *)calloc(1, sizeof(JKTokenCacheItem) * parseState.cache.count)) == NULL) { goto errorExit; }

  return(self);

 errorExit:
  if(self) { [self autorelease]; self = NULL; }
  return(NULL);
}

- (void)dealloc
{
  jk_managedBuffer_release(&parseState.token.tokenBuffer);
  jk_objectStack_release(&parseState.objectStack);

  [self clearCache];
  if(parseState.cache.items != NULL) { free(parseState.cache.items); parseState.cache.items = NULL; }

  [super dealloc];
}

- (void)clearCache
{
  if(parseState.cache.items != NULL) {
    size_t idx = 0UL;
    for(idx = 0UL; idx < parseState.cache.count; idx++) {
      if(parseState.cache.items[idx].object != NULL) { CFRelease(parseState.cache.items[idx].object); parseState.cache.items[idx].object = NULL; }
      if(parseState.cache.items[idx].bytes  != NULL) { free(parseState.cache.items[idx].bytes);       parseState.cache.items[idx].bytes  = NULL; }
#ifndef NS_BLOCK_ASSERTIONS
      memset(&parseState.cache.items[idx], 0, sizeof(JKTokenCacheItem));
#endif
    }
  }
}

- (id)parseUTF8String:(const unsigned char *)string length:(size_t)length
{
  return([self parseUTF8String:string length:length error:NULL]);
}

// This needs to be completely rewritten.
- (id)parseUTF8String:(const unsigned char *)string length:(size_t)length error:(NSError **)error
{
  if(string == NULL) { [NSException raise:NSInvalidArgumentException format:@"The string argument is NULL."]; } 
  if((error != NULL) && (*error != NULL)) { *error = NULL; }

  parseState.stringBuffer.bytes.ptr    = string;
  parseState.stringBuffer.bytes.length = length;
  parseState.atIndex                   = 0UL;
  parseState.lineNumber                = 1UL;
  parseState.lineStartIndex            = 0UL;
  parseState.prev_atIndex              = 0UL;
  parseState.prev_lineNumber           = 1UL;
  parseState.prev_lineStartIndex       = 0UL;
  parseState.error                     = NULL;
  parseState.errorIsPrev               = 0;

  unsigned char stackTokenBuffer[JK_TOKENBUFFER_SIZE] JK_ALIGNED(64);
  jk_managedBuffer_setToStackBuffer(&parseState.token.tokenBuffer, stackTokenBuffer, sizeof(stackTokenBuffer));

  void *stackObjects[JK_STACK_OBJS] JK_ALIGNED(64);
  void *stackKeys   [JK_STACK_OBJS] JK_ALIGNED(64);

  jk_objectStack_setToStackBuffer(&parseState.objectStack, stackObjects, stackKeys, JK_STACK_OBJS);

  id parsedJSON = json_parse_it(&parseState);

#if 0
  if(parsedJSON == NULL) {
    //printf("DEBUG: atIndex: %zu, line: %zu, last token: '%*.*s', atIndex: '%5.5s'\n", parseState.atIndex, parseState.lineNumber, (int)parseState.token.tokenPtrRange.length, (int)parseState.token.tokenPtrRange.length, parseState.token.tokenPtrRange.ptr, (parseState.stringBuffer.bytes.ptr + parseState.atIndex) - 2);
    {
      size_t atIndex        = (parseState.errorIsPrev ? parseState.prev_atIndex : parseState.atIndex);
      //size_t lineNumber     = (parseState.errorIsPrev ? parseState.prev_lineNumber : parseState.lineNumber);
      size_t lineStartIndex = (parseState.errorIsPrev ? parseState.prev_lineStartIndex : parseState.lineStartIndex);
      const unsigned char *lineStart = parseState.stringBuffer.bytes.ptr + lineStartIndex;
      const unsigned char *lineEnd   = lineStart;
      const unsigned char *atCharacterPtr = NULL;
      for(atCharacterPtr = lineStart; atCharacterPtr <= JK_END_STRING_PTR(&parseState); atCharacterPtr++) {
        lineEnd = atCharacterPtr;
        if(jk_parse_is_newline(&parseState, atCharacterPtr)) { break; }
      }
      NSString *lineString = NULL, *carretString = NULL;
      if(lineStart <= JK_END_STRING_PTR(&parseState)) {
        lineString = [[[NSString alloc] initWithBytes:lineStart length:(lineEnd - lineStart) encoding:NSUTF8StringEncoding] autorelease];
        carretString = [NSString stringWithFormat:@"%*.*s^", (int)(atIndex - lineStartIndex), (int)(atIndex - lineStartIndex), " "];
      }
      if((lineString != NULL) && (carretString != NULL)) {
        printf("DEBUG: '%s'\n", [lineString UTF8String]);
        printf("DEBUG:  %s--- HERE\n", [carretString UTF8String]);
      } else {
        printf("DEBUG: Oddly, lineString @ %p || carrentString @ %p == NULL?\n", lineString, carretString);
        printf("DEBUG: '%*.*s'\n", (int)(lineEnd - lineStart), (int)(lineEnd - lineStart), lineStart);
        printf("DEBUG:  %s--- HERE\n", [carretString UTF8String]);
      }
    }

    /*
    if(parseState.error != NULL) {
      NSDictionary *userInfo = [parseState.error userInfo];
      NSString *lineString = [userInfo objectForKey:@"JKErrorLine0Key"];
      NSString *carretString = [userInfo objectForKey:@"JKErrorLine1Key"];
      printf("DEBUG: '%s'\n", [lineString UTF8String]);
      printf("DEBUG:  %s--- HERE\n", [carretString UTF8String]);
    }
    */
  }
#endif

  if((error != NULL) && (parseState.error != NULL)) { *error = parseState.error; }

  jk_managedBuffer_release(&parseState.token.tokenBuffer);
  jk_objectStack_release(&parseState.objectStack);

  parseState.stringBuffer.bytes.ptr    = NULL;
  parseState.stringBuffer.bytes.length = 0UL;
  parseState.atIndex                   = 0UL;
  parseState.lineNumber                = 1UL;
  parseState.lineStartIndex            = 0UL;
  parseState.prev_atIndex              = 0UL;
  parseState.prev_lineNumber           = 1UL;
  parseState.prev_lineStartIndex       = 0UL;
  parseState.error                     = NULL;
  parseState.errorIsPrev               = 0;

  return(parsedJSON);
}

@end

@implementation NSString (JSONKit)

- (id)objectFromJSONString
{
  return([self objectFromJSONStringWithParseOptions:JKParseOptionStrict error:NULL]);
}

- (id)objectFromJSONStringWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  return([self objectFromJSONStringWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)objectFromJSONStringWithParseOptions:(JKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  const unsigned char *utf8String = (const unsigned char *)[self UTF8String];
  if(utf8String == NULL) { return(NULL); }
  size_t               utf8Length = strlen((const char *)utf8String);
  JSONDecoder         *decoder    = [[[JSONDecoder alloc] initWithParseOptions:parseOptionFlags] autorelease];

  return([decoder parseUTF8String:utf8String length:utf8Length error:error]);
}

@end

typedef struct {
  void *stringClass;
  void *numberClass;
  void *arrayClass;
  void *dictionaryClass;
  void *nullClass;
} JKFastClassLookup;

enum {
  JKClassUnknown = 0,
  JKClassString = 1,
  JKClassNumber = 2,
  JKClassArray = 3,
  JKClassDictionary= 4,
  JKClassNull = 5,
};

typedef struct {
  JKManagedBuffer   utf8ConversionBuffer;
  JKManagedBuffer   stringBuffer;
  size_t            atIndex;
  JKFastClassLookup fastClassLookup;
} JKEncodeState;

static int jk_printf(JKEncodeState *encodeState, const char *format, ...) {
  va_list varArgsList;
  va_start(varArgsList, format);
  va_end(varArgsList);

  if(encodeState->stringBuffer.bytes.length < encodeState->atIndex) { return(1); }
  if((encodeState->stringBuffer.bytes.length - encodeState->atIndex) < 1024L) { if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 4096UL) == NULL) { return(1); } }

  char    *atPtr     = (char *)encodeState->stringBuffer.bytes.ptr    + encodeState->atIndex;
  ssize_t  remaining =         encodeState->stringBuffer.bytes.length - encodeState->atIndex;

  int printfAdded = vsnprintf(atPtr, remaining, format, varArgsList);

  if(printfAdded > remaining) {
    if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + printfAdded + 1024UL) == NULL) { return(1); }
    vsnprintf(atPtr, remaining, format, varArgsList);
  }

  encodeState->atIndex += printfAdded;
  return(0);
}

static int jk_write(JKEncodeState *encodeState, const char *format) {
  if(encodeState->stringBuffer.bytes.length < encodeState->atIndex) { return(1); }
  if((encodeState->stringBuffer.bytes.length - encodeState->atIndex) < 1024L) { if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 4096UL) == NULL) { return(1); } }

  char    *atPtr     = (char *)encodeState->stringBuffer.bytes.ptr    + encodeState->atIndex;
  ssize_t  remaining =         encodeState->stringBuffer.bytes.length - encodeState->atIndex;

  ssize_t idx = 0L, added = 0L;
  for(added = 0L, idx = 0L; format[added] != 0; added++) { if(idx < remaining) { atPtr[idx++] = format[added]; } }

  if(added > remaining) {
    if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + added + 1024UL) == NULL) { return(1); }
    for(added = 0L, idx = 0L; format[added] != 0; added++) { if(idx < remaining) { atPtr[idx++] = format[added]; } }
  }

  atPtr[idx] = 0;
  encodeState->atIndex += added;
  return(0);
}



static int jk_add_atom_to_buffer(JKEncodeState *encodeState, void *objectPtr) {
  NSCParameterAssert((encodeState != NULL) && (objectPtr != NULL));
  NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);

  id object = objectPtr;

  if(((encodeState->atIndex + 256UL) > encodeState->stringBuffer.bytes.length) && (jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 256UL) == NULL)) { return(1); }

  int isClass = JKClassUnknown;

       if(object->isa == encodeState->fastClassLookup.stringClass)     { isClass = JKClassString;     }
  else if(object->isa == encodeState->fastClassLookup.numberClass)     { isClass = JKClassNumber;     }
  else if(object->isa == encodeState->fastClassLookup.arrayClass)      { isClass = JKClassArray;      }
  else if(object->isa == encodeState->fastClassLookup.dictionaryClass) { isClass = JKClassDictionary; }
  else if(object->isa == encodeState->fastClassLookup.nullClass)       { isClass = JKClassNull;       }
  else {
         if([object isKindOfClass:[NSString     class]]) { encodeState->fastClassLookup.stringClass     = object->isa; isClass = JKClassString;     }
    else if([object isKindOfClass:[NSNumber     class]]) { encodeState->fastClassLookup.numberClass     = object->isa; isClass = JKClassNumber;     }
    else if([object isKindOfClass:[NSArray      class]]) { encodeState->fastClassLookup.arrayClass      = object->isa; isClass = JKClassArray;      }
    else if([object isKindOfClass:[NSDictionary class]]) { encodeState->fastClassLookup.dictionaryClass = object->isa; isClass = JKClassDictionary; }
    else if([object isKindOfClass:[NSNull       class]]) { encodeState->fastClassLookup.nullClass       = object->isa; isClass = JKClassNull;       }
  }

  switch(isClass) {
    case JKClassString:
      {
        {
          const unsigned char *cStringPtr = (const unsigned char *)CFStringGetCStringPtr((CFStringRef)object, kCFStringEncodingMacRoman);
          if(cStringPtr != NULL) {
            unsigned char *atPtr = encodeState->stringBuffer.bytes.ptr + encodeState->atIndex;
            const unsigned char *utf8String = cStringPtr;
          
            size_t utf8Idx = 0UL, added = 0UL;
            atPtr[added++] = '\"';
            for(utf8Idx = 0UL; utf8String[utf8Idx] != 0; utf8Idx++) {
              NSCParameterAssert(((&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex + added]) - encodeState->stringBuffer.bytes.ptr) < encodeState->stringBuffer.bytes.length);
              NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
              if(((encodeState->atIndex + added + 256UL) > encodeState->stringBuffer.bytes.length)) {
                if((jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + added + 1024UL) == NULL)) { return(1); }
                atPtr = encodeState->stringBuffer.bytes.ptr + encodeState->atIndex;
              }
              if(utf8String[utf8Idx] >= 0x80) { goto slowUTF8Path; }
              if(utf8String[utf8Idx] < 0x20) {
                switch(utf8String[utf8Idx]) {
                  case '\b': atPtr[added++] = '\\'; atPtr[added++] = 'b'; break;
                  case '\f': atPtr[added++] = '\\'; atPtr[added++] = 'f'; break;
                  case '\n': atPtr[added++] = '\\'; atPtr[added++] = 'n'; break;
                  case '\r': atPtr[added++] = '\\'; atPtr[added++] = 'r'; break;
                  case '\t': atPtr[added++] = '\\'; atPtr[added++] = 't'; break;
                  default: jk_printf(encodeState, "\\u%4.4x", utf8String[utf8Idx]); break;
                }
              } else {
                if((utf8String[utf8Idx] == '\"') || (utf8String[utf8Idx] == '\\')) { atPtr[added++] = '\\'; }
                atPtr[added++] = utf8String[utf8Idx];
              }
            }
            atPtr[added++] = '\"';
            atPtr[added] = 0;
            encodeState->atIndex += added;
            return(0);
          }
        }

      slowUTF8Path:
        {
          CFIndex stringLength = CFStringGetLength((CFStringRef)object);
          CFIndex maxStringUTF8Length = CFStringGetMaximumSizeForEncoding(stringLength, kCFStringEncodingUTF8) + 32L;
        
          if(((size_t)maxStringUTF8Length > encodeState->utf8ConversionBuffer.bytes.length) && (jk_managedBuffer_resize(&encodeState->utf8ConversionBuffer, maxStringUTF8Length + 1024UL) == NULL)) { return(1); }
        
          CFIndex usedBytes = 0L, convertedCount = 0L;
          convertedCount = CFStringGetBytes((CFStringRef)object, CFRangeMake(0L, stringLength), kCFStringEncodingUTF8, '?', NO, encodeState->utf8ConversionBuffer.bytes.ptr, encodeState->utf8ConversionBuffer.bytes.length - 16L, &usedBytes);
          encodeState->utf8ConversionBuffer.bytes.ptr[usedBytes] = 0;
        
          if(((encodeState->atIndex + maxStringUTF8Length) > encodeState->stringBuffer.bytes.length) && (jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + maxStringUTF8Length + 1024UL) == NULL)) { return(1); }
        
          unsigned char *atPtr = encodeState->stringBuffer.bytes.ptr + encodeState->atIndex;
          const unsigned char *utf8String = encodeState->utf8ConversionBuffer.bytes.ptr;
        
          size_t utf8Idx = 0UL, added = 0UL;
          atPtr[added++] = '\"';
          for(utf8Idx = 0UL; utf8String[utf8Idx] != 0; utf8Idx++) {
            NSCParameterAssert(((&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex + added]) - encodeState->stringBuffer.bytes.ptr) < encodeState->stringBuffer.bytes.length);
            NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
            NSCParameterAssert((CFIndex)utf8Idx < usedBytes);
            if(((encodeState->atIndex + added + 256UL) > encodeState->stringBuffer.bytes.length)) {
              if((jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + added + 1024UL) == NULL)) { return(1); }
              atPtr = encodeState->stringBuffer.bytes.ptr + encodeState->atIndex;
            }
            if(utf8String[utf8Idx] < 0x20) {
              switch(utf8String[utf8Idx]) {
                case '\b': atPtr[added++] = '\\'; atPtr[added++] = 'b'; break;
                case '\f': atPtr[added++] = '\\'; atPtr[added++] = 'f'; break;
                case '\n': atPtr[added++] = '\\'; atPtr[added++] = 'n'; break;
                case '\r': atPtr[added++] = '\\'; atPtr[added++] = 'r'; break;
                case '\t': atPtr[added++] = '\\'; atPtr[added++] = 't'; break;
                default: jk_printf(encodeState, "\\u%4.4x", utf8String[utf8Idx]); break;
              }
            } else {
              if((utf8String[utf8Idx] == '\"') || (utf8String[utf8Idx] == '\\')) { atPtr[added++] = '\\'; }
              atPtr[added++] = utf8String[utf8Idx];
            }
          }
          atPtr[added++] = '\"';
          atPtr[added] = 0;
          encodeState->atIndex += added;
          return(0);
        }
      }
      break;

    case JKClassNumber:
      {
        if(object == (id)kCFBooleanTrue) { return(jk_write(encodeState, "true")); break; } else if(object == (id)kCFBooleanFalse) { return(jk_write(encodeState, "false")); break; }

        long long llv;
        unsigned long long ullv;
      
        const char *objCType = [object objCType];
        switch(objCType[0]) {
          case 'B':
          case 'c':
            if(object == (id)kCFBooleanTrue) { return(jk_write(encodeState, "true")); }
            else if(object == (id)kCFBooleanFalse) { return(jk_write(encodeState, "false")); }
            else { if(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &llv))  { return(jk_printf(encodeState, "%lld", llv));  } else { return(1); } }
            break;
                    case 'i': case 's': case 'l': case 'q':  if(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &llv))  { return(jk_printf(encodeState, "%lld", llv));  } else { return(1); } break;
          case 'C': case 'I': case 'S': case 'L': case 'Q':  if(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &ullv)) { return(jk_printf(encodeState, "%llu", ullv)); } else { return(1); } break;

          case 'f': case 'd':
            {
              double dv;
              if(CFNumberGetValue((CFNumberRef)object, kCFNumberDoubleType, &dv)) {
                if(!isfinite(dv)) { return(1); }
                return(jk_printf(encodeState, "%.16g", dv));
              }
            }
            break;
          default: jk_printf(encodeState, "/* NSNumber conversion error.  Type: '%c' / 0x%2.2x */", objCType[0], objCType[0]); return(1); break;
        }
      }
      break;
    
    case JKClassArray:
      {
        int printComma = 0;
        CFIndex arrayCount = CFArrayGetCount((CFArrayRef)object), idx = 0L;
        if(jk_write(encodeState, "[")) { return(1); }
        if(arrayCount > 256L) {
          for(id arrayObject in object) { if(printComma) { if(jk_write(encodeState, ",")) { return(1); } } printComma = 1; if(jk_add_atom_to_buffer(encodeState, arrayObject)) { return(1); } }
        } else {
          void *objects[256];
          CFArrayGetValues((CFArrayRef)object, CFRangeMake(0L, arrayCount), (const void **)objects);
          for(idx = 0L; idx < arrayCount; idx++) { if(printComma) { if(jk_write(encodeState, ",")) { return(1); } } printComma = 1; if(jk_add_atom_to_buffer(encodeState, objects[idx])) { return(1); } }
        }
        if(jk_write(encodeState, "]")) { return(1); }
      }
      break;
    case JKClassDictionary:
      {
        int printComma = 0;
        CFIndex dictionaryCount = CFDictionaryGetCount((CFDictionaryRef)object), idx = 0L;

        if(jk_write(encodeState, "{")) { return(1); }
        if(dictionaryCount > 256L) {
          for(id keyObject in object) { if(printComma) { if(jk_write(encodeState, ",")) { return(1); } } printComma = 1; if(jk_add_atom_to_buffer(encodeState, keyObject)) { return(1); } if(jk_write(encodeState, ":")) { return(1); } if(jk_add_atom_to_buffer(encodeState, [object objectForKey:keyObject])) { return(1); } }
        } else {
          void *keys[256], *objects[256];
          CFDictionaryGetKeysAndValues((CFDictionaryRef)object, (const void **)keys, (const void **)objects);
          for(idx = 0L; idx < dictionaryCount; idx++) { if(printComma) { if(jk_write(encodeState, ",")) { return(1); } } printComma = 1; if(jk_add_atom_to_buffer(encodeState, keys[idx])) { return(1); } if(jk_write(encodeState, ":")) { return(1); } if(jk_add_atom_to_buffer(encodeState, objects[idx])) { return(1); } }
        }
        if(jk_write(encodeState, "}")) { return(1); }
      }
      break;

    case JKClassNull: if(jk_write(encodeState, "null")) { return(1); } break;

    default: jk_printf(encodeState, "/* Unable to convert class type of '%s' */", [[object className] UTF8String]); return(1); break;
  }


  return(0);
}


static NSData *jk_encode(void *object) {
  JKEncodeState encodeState;
  memset(&encodeState, 0, sizeof(JKEncodeState));

  encodeState.stringBuffer.roundSizeUpToMultipleOf         = (1024UL * 32UL);
  encodeState.utf8ConversionBuffer.roundSizeUpToMultipleOf = 4096UL;

  unsigned char stackJSONBuffer[JK_JSONBUFFER_SIZE] JK_ALIGNED(64);
  jk_managedBuffer_setToStackBuffer(&encodeState.stringBuffer, stackJSONBuffer, sizeof(stackJSONBuffer));

  unsigned char stackUTF8Buffer[JK_UTF8BUFFER_SIZE] JK_ALIGNED(64);
  jk_managedBuffer_setToStackBuffer(&encodeState.utf8ConversionBuffer, stackUTF8Buffer, sizeof(stackUTF8Buffer));

  NSData *jsonData = NULL;
  if(jk_add_atom_to_buffer(&encodeState, object) == 0) { jsonData = [NSData dataWithBytes:encodeState.stringBuffer.bytes.ptr length:encodeState.atIndex]; }

  jk_managedBuffer_release(&encodeState.stringBuffer);
  jk_managedBuffer_release(&encodeState.utf8ConversionBuffer);

  return(jsonData);
}


@implementation NSArray (JSONKit)

- (NSData *)JSONData
{
  return(jk_encode(self));
}

- (NSString *)JSONString
{
  return([[[NSString alloc] initWithData:[self JSONData] encoding:NSUTF8StringEncoding] autorelease]);
}

@end

@implementation NSDictionary (JSONKit)


- (NSData *)JSONData
{
  return(jk_encode(self));
}

- (NSString *)JSONString
{
  return([[[NSString alloc] initWithData:[self JSONData] encoding:NSUTF8StringEncoding] autorelease]);
}

@end