// qa-approval-anchor - a Secure Enclave signing anchor for the QA-plan approval record.
//
// WHY THIS EXISTS (gstack-extensions#71, #77). The QA-plan approval stamp asserts
// that a HUMAN approved a specific plan. Every earlier version of that record was
// just a file, and the hook that writes it runs as the SAME OS PRINCIPAL as the
// agent, so any file the hook could read the agent could write. That is why the
// token in #76 raised the cost of forgery without eliminating it.
//
// Measured alternatives on this machine, all rejected (see
// spec/plans/qa-plan-approval-trust-anchor.md): a Keychain generic password was
// read straight back by a plain shell with no prompt; pam_tid is not enabled for
// sudo; the session transcript is itself a writable file.
//
// The Secure Enclave holds. The private key is generated INSIDE the Enclave and
// is non-exportable by construction: no API returns it, so shell access does not
// yield the signing capability. Its access control additionally demands user
// presence, so each signature needs a live Touch ID that a script cannot satisfy.
//
// Written in Objective-C rather than Swift because this machine has no Xcode and
// the CommandLineTools swiftc does not match its own SDK. These APIs are C, so
// nothing is lost.
//
//   init          create the key if absent; print public key (base64)
//   pubkey        print public key (base64); never prompts
//   sign <file>   sign the file's bytes; print signature (base64). PROMPTS.
//   verify <file> <sig-b64>   exit 0 valid / 1 invalid; never prompts
//   selftest      prove sign+verify works end to end on this machine

#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSData *TAG(void) { return [@"dev.mujtaba.gstack.qa-approval-anchor" dataUsingEncoding:NSUTF8StringEncoding]; }
#define ALGO kSecKeyAlgorithmECDSASignatureMessageX962SHA256

static void die(NSString *m) { fprintf(stderr, "%s\n", m.UTF8String); exit(2); }

static SecKeyRef loadKey(void) {
    NSDictionary *q = @{ (id)kSecClass: (id)kSecClassKey,
                         (id)kSecAttrApplicationTag: TAG(),
                         (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
                         (id)kSecReturnRef: @YES };
    SecKeyRef k = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, (CFTypeRef *)&k) == errSecSuccess) return k;
    return NULL;
}

static SecKeyRef createKey(void) {
    CFErrorRef err = NULL;
    // .privateKeyUsage gates USE of the key; .userPresence forces a live Touch ID
    // (or the OS fallback) per signature. Together, this is what a shell cannot do.
    SecAccessControlRef acl = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecAccessControlPrivateKeyUsage | kSecAccessControlUserPresence, &err);
    if (!acl) die([NSString stringWithFormat:@"access control failed: %@", err]);
    NSDictionary *attrs = @{
        (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeySizeInBits: @256,
        (id)kSecAttrTokenID: (id)kSecAttrTokenIDSecureEnclave,
        (id)kSecPrivateKeyAttrs: @{ (id)kSecAttrIsPermanent: @YES,
                                    (id)kSecAttrApplicationTag: TAG(),
                                    (id)kSecAttrAccessControl: (__bridge id)acl } };
    SecKeyRef k = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &err);
    if (!k) die([NSString stringWithFormat:@"Secure Enclave key creation failed: %@", err]);
    return k;
}

static NSString *pubB64(SecKeyRef k) {
    SecKeyRef pub = SecKeyCopyPublicKey(k);
    if (!pub) die(@"no public key");
    CFErrorRef err = NULL;
    NSData *d = (__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(pub, &err);
    if (!d) die([NSString stringWithFormat:@"cannot export public key: %@", err]);
    return [d base64EncodedStringWithOptions:0];
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *verb = argc > 1 ? @(argv[1]) : @"";
    if ([verb isEqualToString:@"init"]) {
        SecKeyRef k = loadKey(); if (!k) k = createKey();
        printf("%s\n", pubB64(k).UTF8String); return 0;
    }
    if ([verb isEqualToString:@"pubkey"]) {
        SecKeyRef k = loadKey(); if (!k) die(@"no key; run: qa-approval-anchor init");
        printf("%s\n", pubB64(k).UTF8String); return 0;
    }
    if ([verb isEqualToString:@"sign"] && argc > 2) {
        NSData *d = [NSData dataWithContentsOfFile:@(argv[2])];
        if (!d) die(@"cannot read payload file");
        SecKeyRef k = loadKey(); if (!k) die(@"no key; run: qa-approval-anchor init");
        CFErrorRef err = NULL;
        NSData *sig = (__bridge_transfer NSData *)SecKeyCreateSignature(k, ALGO, (__bridge CFDataRef)d, &err);
        if (!sig) die([NSString stringWithFormat:@"sign failed (presence declined or unavailable): %@", err]);
        printf("%s\n", [sig base64EncodedStringWithOptions:0].UTF8String); return 0;
    }
    if ([verb isEqualToString:@"verify"] && argc > 3) {
        NSData *d = [NSData dataWithContentsOfFile:@(argv[2])];
        NSData *sig = [[NSData alloc] initWithBase64EncodedString:@(argv[3]) options:0];
        if (!d || !sig) die(@"usage: verify <file> <sig-b64>");
        SecKeyRef k = loadKey(); if (!k) die(@"no key");
        SecKeyRef pub = SecKeyCopyPublicKey(k);
        CFErrorRef err = NULL;
        return SecKeyVerifySignature(pub, ALGO, (__bridge CFDataRef)d, (__bridge CFDataRef)sig, &err) ? 0 : 1;
    }
    if ([verb isEqualToString:@"selftest"]) {
        SecKeyRef k = loadKey(); if (!k) k = createKey();
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"qa-anchor-selftest"];
        [[@"anchor selftest payload" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:tmp atomically:YES];
        NSData *d = [NSData dataWithContentsOfFile:tmp];
        CFErrorRef err = NULL;
        NSData *sig = (__bridge_transfer NSData *)SecKeyCreateSignature(k, ALGO, (__bridge CFDataRef)d, &err);
        if (!sig) die([NSString stringWithFormat:@"SIGN FAILED: %@", err]);
        SecKeyRef pub = SecKeyCopyPublicKey(k);
        BOOL ok = SecKeyVerifySignature(pub, ALGO, (__bridge CFDataRef)d, (__bridge CFDataRef)sig, &err);
        printf("%s\n", ok ? "SELFTEST OK (signed and verified via Secure Enclave)" : "SELFTEST FAILED");
        return ok ? 0 : 1;
    }
    die(@"usage: qa-approval-anchor init|pubkey|sign <file>|verify <file> <sig>|selftest");
} }
