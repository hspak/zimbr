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
        // Verified primitive attributed-range structure. Attachment SQL order
        // is deliberately irrelevant: transfer GUID attributes locate images.
        NSString *text = @"Caption 👩🏽‍💻 \uFFFC tail \uFFFC";
        NSMutableAttributedString *parts = [[NSMutableAttributedString alloc] initWithString:text];
        NSRange first = [text rangeOfString:@"\uFFFC"];
        NSRange second = [text rangeOfString:@"\uFFFC" options:NSBackwardsSearch];
        [parts addAttribute:@"__kIMMessagePartAttributeName" value:@0 range:NSMakeRange(0, first.location)];
        [parts addAttributes:@{@"__kIMMessagePartAttributeName": @1, @"__kIMFileTransferGUIDAttributeName": @"11111111-1111-1111-1111-111111111111"} range:first];
        [parts addAttribute:@"__kIMMessagePartAttributeName" value:@2 range:NSMakeRange(NSMaxRange(first), second.location - NSMaxRange(first))];
        [parts addAttributes:@{@"__kIMMessagePartAttributeName": @3, @"__kIMFileTransferGUIDAttributeName": @"22222222-2222-2222-2222-222222222222"} range:second];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSData *body = [NSArchiver archivedDataWithRootObject:parts];
#pragma clang diagnostic pop
        if (![body writeToFile:@"src/relay/adapter/fixtures/foundation-parts.bin" atomically:YES] || ![text writeToFile:@"src/relay/adapter/fixtures/foundation-parts.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
    }
    return 0;
}
