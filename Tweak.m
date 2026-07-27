//
//  LegacyKBFix — Tweak.m  (v0.3)
//
//  App identifiée : chat basé sur Chatto (Badoo).
//    - first responder  : ChattoAdditions.ExpandableTextView
//    - inputAccessoryView : Chatto.(private).KeyboardTrackingView, 85 pt
//      → vue invisible qui RÉSERVE la hauteur de la barre de saisie au-dessus
//        du clavier et observe sa propre position pour placer la barre.
//
//  v0.2 était un no-op : les deux correctifs dépendaient de LKBFRealKeyboardFrame(),
//  qui a renvoyé CGRectNull (la hiérarchie du clavier a changé dans iOS 27 —
//  probablement la même raison pour laquelle Chatto se casse).
//
//  v0.3 :
//    1. kLift s'applique maintenant à la frame SYSTÈME quand la mesure échoue.
//    2. Microscope : dump des fenêtres clavier + chaîne d'ancêtres du first responder.
//
//  Aucune dépendance à Substrate / ellekit : swizzling ObjC pur.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - ==== RÉGLAGES ====

static BOOL    kRepairDefault    = YES;
static BOOL    kAccessoryDefault = YES;
static BOOL    kHUDDefault       = YES;   // microscope
static CGFloat kLiftDefault      = 45.0;  // <<< LE LEVIER. Monte/descend jusqu'à ce que
                                          //     Send réapparaisse (45 → 50 → 60 → 85).

static BOOL LKBFFlag(NSString *key, BOOL fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static CGFloat LKBFNumber(NSString *key, CGFloat fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? (CGFloat)[v doubleValue] : fallback;
}

#pragma mark - Helpers

static UIWindowScene *LKBFActiveScene(void) {
    NSSet *scenes = UIApplication.sharedApplication.connectedScenes;
    for (UIScene *s in scenes)
        if ([s isKindOfClass:UIWindowScene.class] &&
            s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    for (UIScene *s in scenes)
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    return nil;
}

static UIWindow *LKBFKeyWindow(UIWindowScene *ws) {
    for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
    return ws.windows.firstObject;
}

static UIView *LKBFFirstResponder(UIView *root) {
    if (root.isFirstResponder) return root;
    for (UIView *v in root.subviews) {
        UIView *hit = LKBFFirstResponder(v);
        if (hit) return hit;
    }
    return nil;
}

// Les noms Swift sont manglés : la fin est lisible, le début ne l'est pas.
static NSString *LKBFShort(Class c) {
    NSString *n = NSStringFromClass(c);
    if (n.length > 26) n = [n substringFromIndex:n.length - 26];
    return n;
}

#pragma mark - Mesure du clavier (SANS dépendre d'un nom de classe)

// Cherche, dans les fenêtres qui ne sont pas la key window, la vue pleine largeur
// la plus haute dans l'écran : c'est le clavier, quel que soit son nom de classe.
static void LKBFScan(UIView *v, int depth, CGFloat screenW,
                     id<UICoordinateSpace> cs, CGRect *best, NSMutableString *log) {
    if (depth > 6) return;
    for (UIView *sub in v.subviews) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        CGRect f = [sub convertRect:sub.bounds toCoordinateSpace:cs];
        if (f.size.width >= screenW * 0.80 && f.size.height >= 100) {
            if (log) [log appendFormat:@"K%d %@ y=%.0f h=%.0f\n",
                      depth, LKBFShort(sub.class), f.origin.y, f.size.height];
            if (CGRectIsNull(*best) || CGRectGetMinY(f) < CGRectGetMinY(*best)) *best = f;
        }
        LKBFScan(sub, depth + 1, screenW, cs, best, log);
    }
}

static CGRect LKBFRealKeyboardFrame(NSMutableString *log) {
    UIWindowScene *ws = LKBFActiveScene();
    if (!ws) return CGRectNull;
    UIWindow *key = LKBFKeyWindow(ws);
    CGFloat screenW = ws.coordinateSpace.bounds.size.width;

    CGRect best = CGRectNull;
    for (UIWindow *w in ws.windows) {
        if (w == key || w.hidden || w.alpha < 0.01) continue;
        if (log) [log appendFormat:@"W %@\n", LKBFShort(w.class)];
        LKBFScan(w, 0, screenW, ws.coordinateSpace, &best, log);
    }
    return best;
}

#pragma mark - Microscope : chaîne d'ancêtres du first responder

static NSString *LKBFChain(UIView *fr, id<UICoordinateSpace> cs) {
    NSMutableString *s = [NSMutableString string];
    UIView *v = fr;
    for (int i = 0; v && i < 7; i++, v = v.superview) {
        CGRect f = [v convertRect:v.bounds toCoordinateSpace:cs];
        [s appendFormat:@"%d %@ y=%.0f h=%.0f\n", i, LKBFShort(v.class),
                        f.origin.y, f.size.height];
    }
    return s;
}

#pragma mark - HUD

static UILabel *gHUD;

static void LKBFHUD(NSString *text) {
    if (!LKBFFlag(@"LKBF_HUD", kHUDDefault)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *ws = LKBFActiveScene();
        UIWindow *key = ws ? LKBFKeyWindow(ws) : nil;
        if (!key) return;

        if (!gHUD || gHUD.window != key) {
            gHUD = [UILabel new];
            gHUD.numberOfLines = 0;
            gHUD.font = [UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular];
            gHUD.textColor = UIColor.whiteColor;
            gHUD.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.85];
            gHUD.userInteractionEnabled = NO;
            gHUD.layer.zPosition = 9999;
            [key addSubview:gHUD];
        }
        gHUD.text = text;
        gHUD.frame = CGRectMake(2, key.safeAreaInsets.top,
                                key.bounds.size.width - 4, 250);
        [key bringSubviewToFront:gHUD];
    });
}

#pragma mark - Sauvetage de l'accessoire (sur le sommet du clavier, pas sur la mesure)

static CGFloat gKeyboardTop = -1;

static void LKBFRescueAccessory(void) {
    if (!LKBFFlag(@"LKBF_Accessory", kAccessoryDefault)) return;
    if (gKeyboardTop < 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *ws = LKBFActiveScene();
        if (!ws) return;
        UIWindow *key = LKBFKeyWindow(ws);
        UIView *fr = key ? LKBFFirstResponder(key) : nil;
        UIView *acc = fr.inputAccessoryView;
        if (!acc || acc.bounds.size.height <= 0) return;

        CGRect r = [acc convertRect:acc.bounds toCoordinateSpace:ws.coordinateSpace];
        CGFloat overlap = CGRectGetMaxY(r) - gKeyboardTop;
        if (overlap <= 0.5) return;

        acc.transform = CGAffineTransformTranslate(acc.transform, 0, -overlap);
    });
}

#pragma mark - Correction du userInfo

static inline BOOL LKBFIsKeyboardNote(NSString *name) {
    return name.length > 10 && [name hasPrefix:@"UIKeyboard"];
}

static NSDictionary *LKBFRepair(NSString *name, NSDictionary *info) {
    NSValue *endValue = info[UIKeyboardFrameEndUserInfoKey];
    if (![endValue isKindOfClass:NSValue.class]) return info;

    UIWindowScene *ws = LKBFActiveScene();
    CGRect ref = ws ? ws.coordinateSpace.bounds : CGRectZero;
    if (ref.size.height <= 0) return info;

    CGRect given = endValue.CGRectValue;
    CGRect fixed = given;

    NSMutableString *scan = [NSMutableString string];
    CGRect real = LKBFRealKeyboardFrame(scan);

    BOOL hiding = [name isEqualToString:UIKeyboardWillHideNotification] ||
                  [name isEqualToString:UIKeyboardDidHideNotification];

    CGFloat lift = LKBFNumber(@"LKBF_Lift", kLiftDefault);

    if (hiding) {
        fixed.size.width = ref.size.width;
        if (fixed.size.height <= 0) fixed.size.height = 300;
        fixed.origin.x = CGRectGetMinX(ref);
        fixed.origin.y = CGRectGetMaxY(ref);
        gKeyboardTop = -1;
    } else {
        // Base : la mesure si elle a marché, SINON la frame système.
        if (!CGRectIsNull(real) && real.size.height > 0) fixed = real;

        if (fixed.size.height > 0) {
            fixed.origin.y    -= lift;
            fixed.size.height += lift;

            fixed.origin.x   = CGRectGetMinX(ref);
            fixed.size.width = ref.size.width;
            if (fixed.origin.y < CGRectGetMinY(ref) || fixed.origin.y > CGRectGetMaxY(ref))
                fixed.origin.y = CGRectGetMaxY(ref) - fixed.size.height;
            gKeyboardTop = fixed.origin.y;
        }
    }

    // --- microscope ---
    UIWindow *key = ws ? LKBFKeyWindow(ws) : nil;
    UIView *fr = key ? LKBFFirstResponder(key) : nil;
    UIView *acc = fr.inputAccessoryView;
    CGRect accR = acc ? [acc convertRect:acc.bounds toCoordinateSpace:ws.coordinateSpace]
                      : CGRectZero;

    LKBFHUD([NSString stringWithFormat:
             @"%@ lift=%.0f\nsys  h=%.0f y=%.0f\nreal h=%.0f y=%.0f\nfix  h=%.0f y=%.0f\n"
             @"acc %@ y=%.0f h=%.0f\n--- CLAVIER ---\n%@--- CHAINE ---\n%@",
             [name stringByReplacingOccurrencesOfString:@"Notification" withString:@""],
             lift,
             given.size.height, given.origin.y,
             CGRectIsNull(real) ? -1 : real.size.height,
             CGRectIsNull(real) ? -1 : real.origin.y,
             fixed.size.height, fixed.origin.y,
             acc ? LKBFShort(acc.class) : @"(nil)", accR.origin.y, accR.size.height,
             scan.length ? scan : @"(rien trouvé)\n",
             fr ? LKBFChain(fr, ws.coordinateSpace) : @"(pas de FR)\n"]);

    if (!LKBFFlag(@"LKBF_Repair", kRepairDefault)) return info;
    if (CGRectEqualToRect(fixed, given)) return info;

    NSMutableDictionary *m = [info mutableCopy];
    m[UIKeyboardFrameEndUserInfoKey] = [NSValue valueWithCGRect:fixed];

    NSValue *beginValue = info[UIKeyboardFrameBeginUserInfoKey];
    if ([beginValue isKindOfClass:NSValue.class]) {
        CGRect b = beginValue.CGRectValue;
        b.origin.x   = CGRectGetMinX(ref);
        b.size.width = ref.size.width;
        m[UIKeyboardFrameBeginUserInfoKey] = [NSValue valueWithCGRect:b];
    }
    return m;
}

static void LKBFAfterNote(NSString *name) {
    if ([name containsString:@"DidShow"] || [name containsString:@"DidChangeFrame"])
        LKBFRescueAccessory();
}

#pragma mark - Swizzles

static void (*orig_postName)(id, SEL, NSString *, id, NSDictionary *);
static void my_postName(id self, SEL _cmd, NSString *name, id object, NSDictionary *info) {
    if (LKBFIsKeyboardNote(name)) {
        orig_postName(self, _cmd, name, object, LKBFRepair(name, info));
        LKBFAfterNote(name);
        return;
    }
    orig_postName(self, _cmd, name, object, info);
}

static void (*orig_postNote)(id, SEL, NSNotification *);
static void my_postNote(id self, SEL _cmd, NSNotification *n) {
    if (LKBFIsKeyboardNote(n.name)) {
        NSString *name = n.name;
        NSDictionary *fixed = LKBFRepair(name, n.userInfo);
        if (fixed != n.userInfo)
            n = [NSNotification notificationWithName:n.name object:n.object userInfo:fixed];
        orig_postNote(self, _cmd, n);
        LKBFAfterNote(name);
        return;
    }
    orig_postNote(self, _cmd, n);
}

static void LKBFSwizzle(Class cls, SEL sel, IMP replacement, void *origSlot) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *(IMP *)origSlot = method_setImplementation(m, replacement);
}

__attribute__((constructor))
static void LKBFInit(void) {
    @autoreleasepool {
        Class nc = NSNotificationCenter.class;
        LKBFSwizzle(nc, @selector(postNotificationName:object:userInfo:),
                    (IMP)my_postName, &orig_postName);
        LKBFSwizzle(nc, @selector(postNotification:),
                    (IMP)my_postNote,  &orig_postNote);
        NSLog(@"[LegacyKBFix] v0.3 chargé");
    }
}
