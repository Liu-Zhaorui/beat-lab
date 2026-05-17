//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<record_ios/RecordIosPlugin.h>)
#import <record_ios/RecordIosPlugin.h>
#else
@import record_ios;
#endif

#if __has_include(<sound_generator/SoundGeneratorPlugin.h>)
#import <sound_generator/SoundGeneratorPlugin.h>
#else
@import sound_generator;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [RecordIosPlugin registerWithRegistrar:[registry registrarForPlugin:@"RecordIosPlugin"]];
  [SoundGeneratorPlugin registerWithRegistrar:[registry registrarForPlugin:@"SoundGeneratorPlugin"]];
}

@end
