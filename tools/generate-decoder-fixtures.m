// Generates only synthetic archives using Apple's encoder. This is a development
// tool, not a dependency of relay. Run from the repository root on macOS.
#import <Foundation/Foundation.h>
int main(void) {
    @autoreleasepool {
        NSArray<NSString *> *texts = @[@"\nHello e\u0301 👩‍💻\n", [@"emoji 😀\n" stringByPaddingToLength:400 withString:@"abc " startingAtIndex:0]];
        for (NSUInteger i=0; i<texts.count; ++i) {
            NSAttributedString *value = [[NSAttributedString alloc] initWithString:texts[i]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSData *archive = [NSArchiver archivedDataWithRootObject:value];
#pragma clang diagnostic pop
            NSString *stem = [NSString stringWithFormat:@"src/relay/adapter/fixtures/foundation-%lu",(unsigned long)i];
            if (![archive writeToFile:[stem stringByAppendingString:@".bin"] atomically:YES] || ![texts[i] writeToFile:[stem stringByAppendingString:@".txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
        }
    }
    return 0;
}
