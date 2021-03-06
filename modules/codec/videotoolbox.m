/*****************************************************************************
 * videotoolbox.m: Video Toolbox decoder
 *****************************************************************************
 * Copyright © 2014-2015 VideoLabs SAS
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#pragma mark preamble

#ifdef HAVE_CONFIG_H
# import "config.h"
#endif

#import <vlc_common.h>
#import <vlc_plugin.h>
#import <vlc_codec.h>
#import "../packetizer/h264_nal.h"
#import "../video_chroma/copy.h"
#import <vlc_bits.h>

#import <VideoToolbox/VideoToolbox.h>

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <mach/machine.h>

#pragma mark - module descriptor

static int OpenDecoder(vlc_object_t *);
static void CloseDecoder(vlc_object_t *);

#if MAC_OS_X_VERSION_MAX_ALLOWED < 1090
const CFStringRef kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder = CFSTR("EnableHardwareAcceleratedVideoDecoder");
const CFStringRef kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = CFSTR("RequireHardwareAcceleratedVideoDecoder");
#endif

#if !TARGET_OS_IPHONE
#define VT_REQUIRE_HW_DEC N_("Use Hardware decoders only")
#endif

vlc_module_begin()
set_category(CAT_INPUT)
set_subcategory(SUBCAT_INPUT_VCODEC)
set_description(N_("VideoToolbox video decoder"))
set_capability("decoder",800)
set_callbacks(OpenDecoder, CloseDecoder)
#if !TARGET_OS_IPHONE
add_bool("videotoolbox-hw-decoder-only", false, VT_REQUIRE_HW_DEC, VT_REQUIRE_HW_DEC, false)
#endif
vlc_module_end()

#pragma mark - local prototypes

static CFDataRef avvCCreate(decoder_t *, uint8_t *, uint32_t);
static CFDataRef ESDSCreate(decoder_t *, uint8_t *, uint32_t);
static picture_t *DecodeBlock(decoder_t *, block_t **);
static void DecoderCallback(void *, void *, OSStatus, VTDecodeInfoFlags,
                             CVPixelBufferRef, CMTime, CMTime);
void VTDictionarySetInt32(CFMutableDictionaryRef, CFStringRef, int);
static void copy420YpCbCr8Planar(picture_t *, CVPixelBufferRef buffer,
                                 unsigned i_width, unsigned i_height);
static BOOL deviceSupportsAdvancedProfiles();

@interface VTStorageObject : NSObject

@property (retain) NSMutableArray *outputFrames;
@property (retain) NSMutableArray *presentationTimes;

@end

@implementation VTStorageObject
@end

#pragma mark - decoder structure

struct decoder_sys_t
{
    CMVideoCodecType            codec;
    size_t                      codec_profile;
    size_t                      codec_level;

    bool                        b_started;
    VTDecompressionSessionRef   session;
    CMVideoFormatDescriptionRef videoFormatDescription;

    VTStorageObject             *storageObject;
};

#pragma mark - start & stop

static CMVideoCodecType CodecPrecheck(decoder_t *p_dec)
{
    decoder_sys_t *p_sys = p_dec->p_sys;
    size_t i_profile = 0xFFFF, i_level = 0xFFFF;
    bool b_ret = false;
    CMVideoCodecType codec;

    /* check for the codec we can and want to decode */
    switch (p_dec->fmt_in.i_codec) {
        case VLC_CODEC_H264:
            codec = kCMVideoCodecType_H264;

            b_ret = h264_get_profile_level(&p_dec->fmt_in, &i_profile, &i_level, NULL);
            if (!b_ret) {
                msg_Warn(p_dec, "H264 profile and level parsing failed because it didn't arrive yet");
                return kCMVideoCodecType_H264;
            }

            msg_Dbg(p_dec, "trying to decode MPEG-4 Part 10: profile %zu, level %zu", i_profile, i_level);

            switch (i_profile) {
                case PROFILE_H264_BASELINE:
                case PROFILE_H264_MAIN:
                case PROFILE_H264_HIGH:
                    break;

                case PROFILE_H264_HIGH_10:
                {
                    if (deviceSupportsAdvancedProfiles())
                        break;
                }

                default:
                {
                    msg_Dbg(p_dec, "unsupported H264 profile %zu", i_profile);
                    return -1;
                }
            }

#if !TARGET_OS_IPHONE
            /* a level higher than 5.2 was not tested, so don't dare to
             * try to decode it*/
            if (i_level > 52)
                return -1;
#else
            /* on SoC A8, 4.2 is the highest specified profile */
            if (i_level > 42)
                return -1;
#endif

            break;
        case VLC_CODEC_MP4V:
            codec = kCMVideoCodecType_MPEG4Video;
            break;
        case VLC_CODEC_H263:
            codec = kCMVideoCodecType_H263;
            break;

#if !TARGET_OS_IPHONE
            /* there are no DV decoders on iOS, so bailout early */
        case VLC_CODEC_DV:
            /* the VT decoder can't differenciate between PAL and NTSC, so we need to do it */
            switch (p_dec->fmt_in.i_original_fourcc) {
                case VLC_FOURCC( 'd', 'v', 'c', ' '):
                case VLC_FOURCC( 'd', 'v', ' ', ' '):
                    msg_Dbg(p_dec, "Decoding DV NTSC");
                    codec = kCMVideoCodecType_DVCNTSC;
                    break;

                case VLC_FOURCC( 'd', 'v', 's', 'd'):
                case VLC_FOURCC( 'd', 'v', 'c', 'p'):
                case VLC_FOURCC( 'D', 'V', 'S', 'D'):
                    msg_Dbg(p_dec, "Decoding DV PAL");
                    codec = kCMVideoCodecType_DVCPAL;
                    break;

                default:
                    break;
            }
            if (codec != 0)
                break;
#endif
            /* mpgv / mp2v needs fixing, so disabled in non-debug builds */
#ifndef NDEBUG
        case VLC_CODEC_MPGV:
            codec = kCMVideoCodecType_MPEG1Video;
            break;
        case VLC_CODEC_MP2V:
            codec = kCMVideoCodecType_MPEG2Video;
            break;
#endif

        default:
#ifndef NDEBUG
            msg_Err(p_dec, "'%4.4s' is not supported", (char *)&p_dec->fmt_in.i_codec);
#endif
            return -1;
    }

    return codec;
}

static int StartVideoToolbox(decoder_t *p_dec, block_t *p_block)
{
    decoder_sys_t *p_sys = p_dec->p_sys;
    OSStatus status;

    /* setup the decoder */
    CFMutableDictionaryRef decoderConfiguration = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                                                            2,
                                                                            &kCFTypeDictionaryKeyCallBacks,
                                                                            &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(decoderConfiguration,
                         kCVImageBufferChromaLocationBottomFieldKey,
                         kCVImageBufferChromaLocation_Left);
    CFDictionarySetValue(decoderConfiguration,
                         kCVImageBufferChromaLocationTopFieldKey,
                         kCVImageBufferChromaLocation_Left);

    /* fetch extradata */
    CFMutableDictionaryRef extradata_info = NULL;
    CFDataRef extradata = NULL;

    extradata_info = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                               1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);

    int i_video_width = 0;
    int i_video_height = 0;
    int i_sar_den = 0;
    int i_sar_num = 0;

    if (p_sys->codec == kCMVideoCodecType_H264) {
        if ((p_dec->fmt_in.video.i_width == 0 || p_dec->fmt_in.video.i_height == 0) && p_block == NULL) {
            msg_Dbg(p_dec, "waiting for H264 SPS/PPS, extra data %i", p_dec->fmt_in.i_extra);
            return VLC_SUCCESS; // return VLC_GENERIC to leave the waiting to someone else
        }

        uint32_t size;
        void *p_buf;
        int i_ret = 0;

        if (p_block == NULL) {
            /* we are not mid-stream but at the beginning of playback
             * therefore, the demuxer gives us an avvC atom, which can
             * be passed to the decoder with slight or no modifications
             * at all */
            extradata = avvCCreate(p_dec,
                                   (uint8_t*)p_dec->fmt_in.p_extra,
                                   p_dec->fmt_in.i_extra);

            int buf_size = p_dec->fmt_in.i_extra + 20;
            size = p_dec->fmt_in.i_extra;
            p_buf = malloc(buf_size);

            if (!p_buf)
            {
                msg_Warn(p_dec, "extra buffer allocation failed");
                return VLC_ENOMEM;
            }

            /* we need to convert the SPS and PPS units we received from the
             * demxuer's avvC atom so we can process them further */
            i_ret = convert_sps_pps(p_dec,
                                    p_dec->fmt_in.p_extra,
                                    p_dec->fmt_in.i_extra,
                                    p_buf,
                                    buf_size,
                                    &size,
                                    NULL);
        } else {
            /* we are mid-stream, let's have the h264_get helper see if it
             * can find a NAL unit */
            size = p_block->i_buffer;
            p_buf = p_block->p_buffer;
            i_ret = VLC_SUCCESS;
        }

        if (i_ret == VLC_SUCCESS) {
            uint8_t *p_sps_buf = NULL, *p_pps_buf = NULL;
            size_t i_sps_size = 0, i_pps_size = 0;

            /* get the SPS and PPS units from the NAL unit which is either
             * part of the demuxer's avvC atom or the mid stream data block */
            i_ret = h264_get_spspps(p_buf,
                                    size,
                                    &p_sps_buf,
                                    &i_sps_size,
                                    &p_pps_buf,
                                    &i_pps_size);

            if (i_ret == VLC_SUCCESS) {
                struct nal_sps sps_data;
                i_ret = h264_parse_sps(p_sps_buf,
                                       i_sps_size,
                                       &sps_data);

                if (i_ret == VLC_SUCCESS) {
                    /* this data is more trust-worthy than what we receive
                     * from the demuxer, so we will use it to over-write
                     * the current values */
                    i_video_width = sps_data.i_width;
                    i_video_height = sps_data.i_height;
                    i_sar_den = sps_data.vui.i_sar_den;
                    i_sar_num = sps_data.vui.i_sar_num;

                    /* no evaluation here as this is done in the precheck */
                    p_sys->codec_profile = sps_data.i_profile;
                    p_sys->codec_level = sps_data.i_level;

                    if (p_block != NULL) {
                        /* on mid stream changes, we have a block and need to
                         * glue our own avvC atom together to give it to the
                         * decoder */

                        bo_t bo;
                        bool status = bo_init(&bo, 1024);

                        if (status != true)
                            return VLC_ENOMEM;

                        bo_add_8(&bo, 1);      /* configuration version */
                        bo_add_8(&bo, sps_data.i_profile);
                        bo_add_8(&bo, sps_data.i_profile_compatibility);
                        bo_add_8(&bo, sps_data.i_level);
                        bo_add_8(&bo, 0xff);   /* 0b11111100 | lengthsize = 0x11 */

                        bo_add_8(&bo, 0xe0 | (i_sps_size > 0 ? 1 : 0));   /* 0b11100000 | sps_count */

                        if (i_sps_size > 4) {
                            /* the SPS data we have got includes 4 leading
                             * bytes which we need to remove */
                            uint8_t *fixed_sps = malloc(i_sps_size - 4);
                            for (int i = 0; i < i_sps_size - 4; i++) {
                                fixed_sps[i] = p_sps_buf[i+4];
                            }

                            bo_add_16be(&bo, i_sps_size - 4);
                            bo_add_mem(&bo, i_sps_size - 4, fixed_sps);
                            free(fixed_sps);
                        }

                        bo_add_8(&bo, (i_pps_size > 0 ? 1 : 0));   /* pps_count */
                        if (i_pps_size > 4) {
                            /* the PPS data we have got includes 4 leading
                             * bytes which we need to remove */
                            uint8_t *fixed_pps = malloc(i_pps_size - 4);
                            for (int i = 0; i < i_pps_size - 4; i++) {
                                fixed_pps[i] = p_pps_buf[i+4];
                            }

                            bo_add_16be(&bo, i_pps_size - 4);
                            bo_add_mem(&bo, i_pps_size - 4, fixed_pps);
                            free(fixed_pps);
                        }

                        extradata = CFDataCreate(kCFAllocatorDefault,
                                                 bo.b->p_buffer,
                                                 bo.b->i_buffer);
                    }
                }
            }
        }

        if (extradata)
            CFDictionarySetValue(extradata_info, CFSTR("avcC"), extradata);

        CFDictionarySetValue(decoderConfiguration,
                             kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
                             extradata_info);

    } else if (p_sys->codec == kCMVideoCodecType_MPEG4Video) {
        extradata = ESDSCreate(p_dec,
                               (uint8_t*)p_dec->fmt_in.p_extra,
                               p_dec->fmt_in.i_extra);

        if (extradata)
            CFDictionarySetValue(extradata_info, CFSTR("esds"), extradata);

        CFDictionarySetValue(decoderConfiguration,
                             kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
                             extradata_info);
    } else {
        CFDictionarySetValue(decoderConfiguration,
                             kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
                             extradata_info);
    }

    if (extradata)
        CFRelease(extradata);
    CFRelease(extradata_info);

    /* pixel aspect ratio */
    CFMutableDictionaryRef pixelaspectratio = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                                                        2,
                                                                        &kCFTypeDictionaryKeyCallBacks,
                                                                        &kCFTypeDictionaryValueCallBacks);
    /* fallback on the demuxer if we don't have better info */
    if (i_video_width == 0)
        i_video_width = p_dec->fmt_in.video.i_width;
    if (i_video_height == 0)
        i_video_height = p_dec->fmt_in.video.i_height;
    if (i_sar_num == 0)
        i_sar_num = p_dec->fmt_in.video.i_sar_num ? p_dec->fmt_in.video.i_sar_num : 1;
    if (i_sar_den == 0)
        i_sar_den = p_dec->fmt_in.video.i_sar_den ? p_dec->fmt_in.video.i_sar_den : 1;

    VTDictionarySetInt32(pixelaspectratio,
                         kCVImageBufferPixelAspectRatioHorizontalSpacingKey,
                         i_sar_num);
    VTDictionarySetInt32(pixelaspectratio,
                         kCVImageBufferPixelAspectRatioVerticalSpacingKey,
                         i_sar_den);
    CFDictionarySetValue(decoderConfiguration,
                         kCVImageBufferPixelAspectRatioKey,
                         pixelaspectratio);
    CFRelease(pixelaspectratio);

#if !TARGET_OS_IPHONE
    /* enable HW accelerated playback, since this is optional on OS X
     * note that the backend may still fallback on software mode if no
     * suitable hardware is available */
    CFDictionarySetValue(decoderConfiguration,
                         kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
                         kCFBooleanTrue);

    /* on OS X, we can force VT to fail if no suitable HW decoder is available,
     * preventing the aforementioned SW fallback */
    if (var_InheritInteger(p_dec, "videotoolbox-hw-decoder-only"))
        CFDictionarySetValue(decoderConfiguration,
                             kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder,
                             kCFBooleanTrue);
#endif

    /* create video format description */
    status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                            p_sys->codec,
                                            i_video_width,
                                            i_video_height,
                                            decoderConfiguration,
                                            &p_sys->videoFormatDescription);
    if (status) {
        CFRelease(decoderConfiguration);
        msg_Err(p_dec, "video format description creation failed (%i)", status);
        return VLC_EGENERIC;
    }

    /* destination pixel buffer attributes */
    CFMutableDictionaryRef dpba = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                                            2,
                                                            &kCFTypeDictionaryKeyCallBacks,
                                                            &kCFTypeDictionaryValueCallBacks);
    /* we need to change the following keys for convienence
     * conversations as soon as we have a 0-copy pipeline */
#if !TARGET_OS_IPHONE
    CFDictionarySetValue(dpba,
                         kCVPixelBufferOpenGLCompatibilityKey,
                         kCFBooleanFalse);
#else
    CFDictionarySetValue(dpba,
                         kCVPixelBufferOpenGLESCompatibilityKey,
                         kCFBooleanFalse);
#endif
    VTDictionarySetInt32(dpba,
                         kCVPixelBufferPixelFormatTypeKey,
                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    VTDictionarySetInt32(dpba,
                         kCVPixelBufferWidthKey,
                         i_video_width);
    VTDictionarySetInt32(dpba,
                         kCVPixelBufferHeightKey,
                         i_video_height);
    VTDictionarySetInt32(dpba,
                         kCVPixelBufferBytesPerRowAlignmentKey,
                         i_video_width * 2);

    /* setup storage */
    p_sys->storageObject = [[VTStorageObject alloc] init];
    p_sys->storageObject.outputFrames = [[NSMutableArray alloc] init];
    p_sys->storageObject.presentationTimes = [[NSMutableArray alloc] init];

    /* setup decoder callback record */
    VTDecompressionOutputCallbackRecord decoderCallbackRecord;
    decoderCallbackRecord.decompressionOutputCallback = DecoderCallback;
    decoderCallbackRecord.decompressionOutputRefCon = p_dec;

    /* create decompression session */
    status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                          p_sys->videoFormatDescription,
                                          decoderConfiguration,
                                          dpba,
                                          &decoderCallbackRecord,
                                          &p_sys->session);

    /* release no longer needed storage items */
    CFRelease(dpba);
    CFRelease(decoderConfiguration);

    /* check if the session is valid */
    if (status) {

        switch (status) {
            case -12470:
                msg_Err(p_dec, "VT is not supported on this hardware");
                break;
            case -12471:
                msg_Err(p_dec, "Video format is not supported by VT");
                break;
            case -12903:
                msg_Err(p_dec, "created session is invalid, could not select and open decoder instance");
                break;
            case -12906:
                msg_Err(p_dec, "could not find decoder");
                break;
            case -12910:
                msg_Err(p_dec, "unsupported data");
                break;
            case -12913:
                msg_Err(p_dec, "VT is not available to sandboxed apps on this OS release");
                break;
            case -12917:
                msg_Err(p_dec, "Insufficient source color data");
                break;
            case -12918:
                msg_Err(p_dec, "Could not create color correction data");
                break;
            case -12210:
                msg_Err(p_dec, "Insufficient authorization to create decoder");
                break;

            default:
                msg_Err(p_dec, "Decompression session creation failed (%i)", status);
                break;
        }
        /* an invalid session is an inrecoverable failure */
        p_dec->b_error = true;

        return VLC_EGENERIC;
    }

    p_dec->fmt_out.video.i_width = i_video_width;
    p_dec->fmt_out.video.i_height = i_video_height;
    p_dec->fmt_out.video.i_sar_den = i_sar_den;
    p_dec->fmt_out.video.i_sar_num = i_sar_num;

    /* fix the demuxer's findings are NULL, we assume that video dimensions
     * and visible video dimensions are the same */
    if (!p_dec->fmt_in.video.i_visible_width)
        p_dec->fmt_in.video.i_visible_width = i_video_width;
    if (!p_dec->fmt_in.video.i_visible_height)
        p_dec->fmt_in.video.i_visible_height = i_video_height;

    if (p_block) {
        /* this is a mid stream change so we need to tell the core about it */
        decoder_UpdateVideoFormat(p_dec);
        block_Release(p_block);
    }

    p_sys->b_started = YES;

    return VLC_SUCCESS;
}

static void StopVideoToolbox(decoder_t *p_dec)
{
    decoder_sys_t *p_sys = p_dec->p_sys;

    if (p_sys->b_started) {
        p_sys->b_started = false;
        if (p_sys->session != NULL) {
            VTDecompressionSessionInvalidate(p_sys->session);
            CFRelease(p_sys->session);
            p_sys->session = NULL;
        }
    }

    if (p_sys->videoFormatDescription != NULL)
        CFRelease(p_sys->videoFormatDescription);
}

#pragma mark - module open and close

static int OpenDecoder(vlc_object_t *p_this)
{
    decoder_t *p_dec = (decoder_t *)p_this;
    CMVideoCodecType codec;

    /* check quickly if we can digest the offered data */
    codec = CodecPrecheck(p_dec);
    if (codec == -1)
        return VLC_EGENERIC;

    /* now that we see a chance to decode anything, allocate the
     * internals and start the decoding session */
    decoder_sys_t *p_sys;
    p_sys = malloc(sizeof(*p_sys));
    if (!p_sys)
        return VLC_ENOMEM;
    p_dec->p_sys = p_sys;
    p_sys->b_started = false;
    p_sys->codec = codec;

    int i_ret = StartVideoToolbox(p_dec, NULL);
    if (i_ret != VLC_SUCCESS) {
        CloseDecoder(p_this);
        return i_ret;
    }

    /* return our proper VLC internal state */
    p_dec->fmt_out.i_cat = VIDEO_ES;
    p_dec->fmt_out.i_codec = VLC_CODEC_I420;

    p_dec->b_need_packetized = true;

    p_dec->pf_decode_video = DecodeBlock;

    msg_Info(p_dec, "Using Video Toolbox to decode '%4.4s'", (char *)&p_dec->fmt_in.i_codec);

    return VLC_SUCCESS;
}

static void CloseDecoder(vlc_object_t *p_this)
{
    decoder_t *p_dec = (decoder_t *)p_this;
    decoder_sys_t *p_sys = p_dec->p_sys;

    if (p_sys->session && p_sys->b_started) {
        VTDecompressionSessionWaitForAsynchronousFrames(p_sys->session);
    }
    StopVideoToolbox(p_dec);

    free(p_sys);
}

#pragma mark - helpers

static BOOL deviceSupportsAdvancedProfiles()
{
#if TARGET_IPHONE_SIMULATOR
    return NO;
#endif
#if TARGET_OS_IPHONE
    size_t size;
    cpu_type_t type;

    size = sizeof(type);
    sysctlbyname("hw.cputype", &type, &size, NULL, 0);

    /* Support for H264 profile HIGH 10 was introduced with the first 64bit Apple ARM SoC, the A7 */
    if (type == CPU_TYPE_ARM64)
        return YES;

    return NO;
#else
    return NO;
#endif
}

static inline void bo_add_mp4_tag_descr(bo_t *p_bo, uint8_t tag, uint32_t size)
{
    bo_add_8(p_bo, tag);
    for (int i = 3; i>0; i--)
        bo_add_8(p_bo, (size>>(7*i)) | 0x80);
    bo_add_8(p_bo, size & 0x7F);
}

static CFDataRef avvCCreate(decoder_t *p_dec, uint8_t *p_buf, uint32_t i_buf_size)
{
    VLC_UNUSED(p_dec);
    CFDataRef data;

    /* each NAL sent to the decoder is preceded by a 4 byte header
     * we need to change the avcC header to signal headers of 4 bytes, if needed */
    if (i_buf_size >= 4 && (p_buf[4] & 0x03) != 0x03) {
        uint8_t *p_fixed_buf;
        p_fixed_buf = malloc(i_buf_size);
        if (!p_fixed_buf)
            return NULL;

        memcpy(p_fixed_buf, p_buf, i_buf_size);
        p_fixed_buf[4] |= 0x03;

        data = CFDataCreate(kCFAllocatorDefault,
                            p_fixed_buf,
                            i_buf_size);
    } else {
        data = CFDataCreate(kCFAllocatorDefault,
                            p_buf,
                            i_buf_size);
    }

    return data;
}

static CFDataRef ESDSCreate(decoder_t *p_dec, uint8_t *p_buf, uint32_t i_buf_size)
{
    int full_size = 3 + 5 +13 + 5 + i_buf_size + 3;
    int config_size = 13 + 5 + i_buf_size;
    int padding = 12;

    bo_t bo;
    bool status = bo_init(&bo, 1024);
    if (status != true)
        return NULL;

    bo_add_8(&bo, 0);       // Version
    bo_add_24be(&bo, 0);    // Flags

    // elementary stream description tag
    bo_add_mp4_tag_descr(&bo, 0x03, full_size);
    bo_add_16be(&bo, 0);    // esid
    bo_add_8(&bo, 0);       // stream priority (0-3)

    // decoder configuration description tag
    bo_add_mp4_tag_descr(&bo, 0x04, config_size);
    bo_add_8(&bo, 32);      // object type identification (32 == MPEG4)
    bo_add_8(&bo, 0x11);    // stream type
    bo_add_24be(&bo, 0);    // buffer size
    bo_add_32be(&bo, 0);    // max bitrate
    bo_add_32be(&bo, 0);    // avg bitrate

    // decoder specific description tag
    bo_add_mp4_tag_descr(&bo, 0x05, i_buf_size);
    bo_add_mem(&bo, i_buf_size, p_buf);

    // sync layer configuration description tag
    bo_add_8(&bo, 0x06);    // tag
    bo_add_8(&bo, 0x01);    // length
    bo_add_8(&bo, 0x02);    // no SL

    CFDataRef data = CFDataCreate(kCFAllocatorDefault,
                                  bo.b->p_buffer,
                                  bo.b->i_buffer);
    return data;
}

static bool H264ProcessBlock(decoder_t *p_dec, block_t *p_block)
{
    decoder_sys_t *p_sys = p_dec->p_sys;
    int buf_size = p_dec->fmt_in.i_extra + 20;
    uint32_t size = p_dec->fmt_in.i_extra;
    void *p_buf = malloc(buf_size);

    if (!p_buf)
    {
        msg_Warn(p_dec, "extra buffer allocation failed");
        return false;
    }

    uint8_t *p_sps_buf = NULL, *p_pps_buf = NULL;
    size_t i_sps_size = 0, i_pps_size = 0;
    int i_ret = 0;

    i_ret = h264_get_spspps(p_block->p_buffer,
                            p_block->i_buffer,
                            &p_sps_buf,
                            &i_sps_size,
                            &p_pps_buf,
                            &i_pps_size);

    if (i_ret == VLC_SUCCESS) {
        struct nal_sps sps_data;
        i_ret = h264_parse_sps(p_sps_buf,
                               i_sps_size,
                               &sps_data);

        if (i_ret == VLC_SUCCESS) {
            bool b_something_changed = false;

            if (p_sys->codec_profile != sps_data.i_profile) {
                msg_Warn(p_dec, "mid stream profile change found, restarting decoder");
                b_something_changed = true;
            } else if (p_sys->codec_level != sps_data.i_level) {
                msg_Warn(p_dec, "mid stream level change found, restarting decoder");
                b_something_changed = true;
            } else if (p_dec->fmt_out.video.i_width != sps_data.i_width) {
                msg_Warn(p_dec, "mid stream width change found, restarting decoder");
                b_something_changed = true;
            } else if (p_dec->fmt_out.video.i_height != sps_data.i_height) {
                msg_Warn(p_dec, "mid stream height change found, restarting decoder");
                b_something_changed = true;
            } else if (p_dec->fmt_out.video.i_sar_den != sps_data.vui.i_sar_den) {
                msg_Warn(p_dec, "mid stream SAR DEN change found, restarting decoder");
                b_something_changed = true;
            } else if (p_dec->fmt_out.video.i_sar_num != sps_data.vui.i_sar_num) {
                msg_Warn(p_dec, "mid stream SAR NUM change found, restarting decoder");
                b_something_changed = true;
            }

            if (b_something_changed) {
                p_sys->codec_profile = sps_data.i_profile;
                p_sys->codec_level = sps_data.i_level;
                StopVideoToolbox(p_dec);
                return false;
            }
        }
    }

    return true;
}

static CMSampleBufferRef VTSampleBufferCreate(decoder_t *p_dec,
                                              CMFormatDescriptionRef fmt_desc,
                                              void *buffer,
                                              int size,
                                              mtime_t i_pts,
                                              mtime_t i_dts,
                                              mtime_t i_length)
{
    OSStatus status;
    CMBlockBufferRef  block_buf = NULL;
    CMSampleBufferRef sample_buf = NULL;

    CMSampleTimingInfo timeInfo;
    CMSampleTimingInfo timeInfoArray[1];

    timeInfo.duration = CMTimeMake(i_length, 1);
    timeInfo.presentationTimeStamp = CMTimeMake(i_pts > 0 ? i_pts : i_dts, CLOCK_FREQ);
    timeInfo.decodeTimeStamp = CMTimeMake(i_dts, CLOCK_FREQ);
    timeInfoArray[0] = timeInfo;

    status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,// structureAllocator
                                                buffer,             // memoryBlock
                                                size,               // blockLength
                                                kCFAllocatorNull,   // blockAllocator
                                                NULL,               // customBlockSource
                                                0,                  // offsetToData
                                                size,               // dataLength
                                                false,              // flags
                                                &block_buf);

    if (!status) {
        status = CMSampleBufferCreate(kCFAllocatorDefault,  // allocator
                                      block_buf,            // dataBuffer
                                      TRUE,                 // dataReady
                                      0,                    // makeDataReadyCallback
                                      0,                    // makeDataReadyRefcon
                                      fmt_desc,             // formatDescription
                                      1,                    // numSamples
                                      1,                    // numSampleTimingEntries
                                      timeInfoArray,        // sampleTimingArray
                                      0,                    // numSampleSizeEntries
                                      NULL,                 // sampleSizeArray
                                      &sample_buf);
        if (status != noErr)
            msg_Warn(p_dec, "sample buffer creation failure %i", status);
    } else
        msg_Warn(p_dec, "cm block buffer creation failure %i", status);

    if (block_buf)
        CFRelease(block_buf);

    return sample_buf;
}

void VTDictionarySetInt32(CFMutableDictionaryRef dict, CFStringRef key, int value)
{
    CFNumberRef number;
    number = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
    CFDictionarySetValue(dict, key, number);
    CFRelease(number);
}

static void copy420YpCbCr8Planar(picture_t *p_pic,
                                 CVPixelBufferRef buffer,
                                 unsigned i_width,
                                 unsigned i_height)
{
    uint8_t *pp_plane[2];
    size_t pi_pitch[2];

    if (!buffer)
        return;

    CVPixelBufferLockBaseAddress(buffer, 0);

    for (int i = 0; i < 2; i++) {
        pp_plane[i] = CVPixelBufferGetBaseAddressOfPlane(buffer, i);
        pi_pitch[i] = CVPixelBufferGetBytesPerRowOfPlane(buffer, i);
    }

    CopyFromNv12ToI420(p_pic, pp_plane, pi_pitch, i_width, i_height);

    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

#pragma mark - actual decoding

static picture_t *DecodeBlock(decoder_t *p_dec, block_t **pp_block)
{
    decoder_sys_t *p_sys = p_dec->p_sys;
    block_t *p_block;
    VTDecodeFrameFlags decoderFlags = 0;
    VTDecodeInfoFlags flagOut;
    OSStatus status;
    int i_ret = 0;

    if (!pp_block)
        return NULL;

    p_block = *pp_block;

    if (likely(p_block)) {
        if (unlikely(p_block->i_flags&(BLOCK_FLAG_DISCONTINUITY|BLOCK_FLAG_CORRUPTED))) { // p_block->i_dts < VLC_TS_INVALID ||
            block_Release(p_block);
            goto skip;
        }

        /* feed to vt */
        if (likely(p_block->i_buffer)) {
            if (!p_sys->b_started) {
                /* decoding didn't start yet, which is ok for H264, let's see
                 * if we can use this block to get going */
                p_sys->codec = kCMVideoCodecType_H264;
                i_ret = StartVideoToolbox(p_dec, p_block);
            }
            if (i_ret != VLC_SUCCESS || !p_sys->b_started)
                return NULL;

            if (p_sys->codec == kCMVideoCodecType_H264) {
                if (!H264ProcessBlock(p_dec, p_block))
                    return NULL;
            }

            CMSampleBufferRef sampleBuffer;
            sampleBuffer = VTSampleBufferCreate(p_dec,
                                                p_sys->videoFormatDescription,
                                                p_block->p_buffer,
                                                p_block->i_buffer,
                                                p_block->i_pts,
                                                p_block->i_dts,
                                                p_block->i_length);
            if (sampleBuffer) {
                decoderFlags = kVTDecodeFrame_EnableAsynchronousDecompression;

                status = VTDecompressionSessionDecodeFrame(p_sys->session,
                                                           sampleBuffer,
                                                           decoderFlags,
                                                           NULL, // sourceFrameRefCon
                                                           &flagOut); // infoFlagsOut
                if (status != noErr) {
                    if (status == kCVReturnInvalidSize)
                        msg_Err(p_dec, "decoder failure: invalid block size");
                    else if (status == -666)
                        msg_Err(p_dec, "decoder failure: invalid SPS/PPS");
                    else if (status == -6661) {
                        msg_Err(p_dec, "decoder failure: invalid argument");
                        p_dec->b_error = true;
                    } else if (status == -8969 || status == -12909) {
                        msg_Err(p_dec, "decoder failure: bad data");
                        p_dec->b_error = true;
                    } else if (status == -12911 || status == -8960) {
                        msg_Err(p_dec, "decoder failure: internal malfunction");
                        p_dec->b_error = true;
                    } else
                        msg_Dbg(p_dec, "decoding frame failed (%i)", status);
                }

                CFRelease(sampleBuffer);
            }
        }

        block_Release(p_block);
    }

skip:

    *pp_block = NULL;

    if ([p_sys->storageObject.outputFrames count] && [p_sys->storageObject.presentationTimes count]) {
        CVPixelBufferRef imageBuffer = NULL;
        NSNumber *framePTS = nil;
        id imageBufferObject = nil;
        picture_t *p_pic = NULL;

        @synchronized(p_sys->storageObject) {
            framePTS = [p_sys->storageObject.presentationTimes firstObject];
            imageBufferObject = [p_sys->storageObject.outputFrames firstObject];
            imageBuffer = (__bridge CVPixelBufferRef)imageBufferObject;

            if (imageBuffer != NULL) {
                if (CVPixelBufferGetDataSize(imageBuffer) > 0) {
                    p_pic = decoder_NewPicture(p_dec);

                    if (!p_pic)
                        return NULL;

                    /* ehm, *cough*, memcpy.. */
                    copy420YpCbCr8Planar(p_pic,
                                         imageBuffer,
                                         CVPixelBufferGetWidthOfPlane(imageBuffer, 0),
                                         CVPixelBufferGetHeightOfPlane(imageBuffer, 0));

                    p_pic->date = framePTS.longLongValue;

                    if (imageBufferObject)
                        [p_sys->storageObject.outputFrames removeObjectAtIndex:0];

                    if (framePTS)
                        [p_sys->storageObject.presentationTimes removeObjectAtIndex:0];
                }
            }
        }
        return p_pic;
    }

    return NULL;
}

static void DecoderCallback(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVPixelBufferRef imageBuffer,
                             CMTime pts,
                             CMTime duration)
{
    VLC_UNUSED(sourceFrameRefCon);
    VLC_UNUSED(duration);
    decoder_t *p_dec = (decoder_t *)decompressionOutputRefCon;
    decoder_sys_t *p_sys = p_dec->p_sys;

#ifndef NDEBUG
    static BOOL outputdone = NO;
    if (!outputdone) {
        /* attachments include all kind of debug info */
        CFDictionaryRef attachments = CVBufferGetAttachments(imageBuffer,
                                                             kCVAttachmentMode_ShouldPropagate);
        NSLog(@"%@", attachments);
        outputdone = YES;
    }
#endif

    if (status != noErr) {
        msg_Warn(p_dec, "decoding of a frame failed (%i, %u)", status, (unsigned int) infoFlags);
        return;
    }

    if (imageBuffer == NULL)
        return;

    if (infoFlags & kVTDecodeInfo_FrameDropped) {
        msg_Dbg(p_dec, "decoder dropped frame");
        CFRelease(imageBuffer);
        return;
    }

    NSNumber *framePTS = nil;

    if (CMTIME_IS_VALID(pts))
        framePTS = [NSNumber numberWithLongLong:pts.value];
    else {
        msg_Dbg(p_dec, "invalid timestamp, dropping frame");
        CFRelease(imageBuffer);
        return;
    }

    if (framePTS) {
        @synchronized(p_sys->storageObject) {
            id imageBufferObject = (__bridge id)imageBuffer;
            BOOL shouldStop = YES;
            NSInteger insertionIndex = [p_sys->storageObject.presentationTimes count] - 1;
            while (insertionIndex >= 0 && shouldStop == NO) {
                NSNumber *aNumber = p_sys->storageObject.presentationTimes[insertionIndex];
                if ([aNumber longLongValue] <= [framePTS longLongValue]) {
                    shouldStop = YES;
                    break;
                }
                insertionIndex--;
            }

            /* re-order frames on presentation times using a double mutable array structure */
            if (insertionIndex + 1 == [p_sys->storageObject.presentationTimes count]) {
                [p_sys->storageObject.presentationTimes addObject:framePTS];
                [p_sys->storageObject.outputFrames addObject:imageBufferObject];
            } else {
                [p_sys->storageObject.presentationTimes insertObject:framePTS atIndex:insertionIndex + 1];
                [p_sys->storageObject.outputFrames insertObject:framePTS atIndex:insertionIndex + 1];
            }
        }
    }
}
