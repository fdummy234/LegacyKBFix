//
//  LegacyKBFix — Tweak.m  (v0.4)
//
//  DIAGNOSTIC ÉTABLI (dump v0.3, iOS 27, app Chatto/Badoo) :
//
//    vrai clavier    UIKeyboardItemContainerView   y=598  h=298   (bas = 896)
//    frame annoncée  notification UIKeyboard*      y=636  h=320   (bas = 956)
//
//    Les vues de l'app vivent dans un espace de 896 de haut ; la notification est
//    exprimée dans un espace de 956. Chatto place donc sa ChatInputBar par rapport
//    à 636 au lieu de 598 → 38 pt trop bas → la rangée Aa/Send passe sous le clavier.
//    (Barre de 85 pt occupant 551→636, recouverte à partir de 598 : 47 pt visibles
//     en haut, 38 pt cachés en bas. Conforme aux captures.)
//
//  CORRECTIF : remplacer la frame de la notification par la vraie mesure, prise
//  dans l'espace de coordonnées de la scène — donc cohérente par construction.
//
//  v0.3 cassait l'écran : le scan retenait UITrackingWindowView (y=0 h=896), soit
//  l'écran entier. D'où les garde-fous ci-dessous — une mesure aberrante est
//  désormais jetée, jamais injectée.
//
//  Aucune dépendance à Substrate / ellekit : swizzling ObjC pur.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - ==== RÉGLAGES ====

static BOOL    kRepairDefault    = YES;
static BOOL    kAccessoryDefault = NO;    // pas le bon levier : ne pas toucher au
                                          // KeyboardTrackingView de Chatto
static BOOL    kHUDDefault       = YES;   // mets NO pour le build final
static CGFloat kLiftDefault      = 0.0;   // ajustement fin si la barre rate encore
                                          // de quelques points (+ = remonte)

// Garde-fous : une frame clavier plausible est ancrée en bas et ne dépasse pas
// cette fraction de la hauteur d'écran. Au-delà, on jette la mesure.
static const CGFloat kMaxKeyboardFraction = 0.70;
static const CGFloat kBottomTolerance     = 6.0;

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

#pragma mark - Mesure du clavier

// Un candidat clavier doit être :
//   - pleine largeur (≥ 80 % de la scène)
//   - ancré au BAS de la scène (maxY ≈ bas, à kBottomTolerance près)
//   - d'une hauteur crédible : ≥ 100 pt et ≤ kMaxKeyboardFraction de l'écran
// Ça élimine UITrackingWindowView et UIEditingOverlayGestureView (plein écran),
// qui avaient piégé la v0.3.
static void LKBFScan(UIView *v, int depth, CGRect ref,
                     id<UICoordinateSpace> cs, CGRect *best) {
    if (depth > 6) return;
    for (UIView *sub in v.subviews) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        CGRect f = [sub convertRect:sub.bounds toCoordinateSpace:cs];

        BOOL wide      = f.size.width  >= ref.size.width * 0.80;
        BOOL tallEnough = f.size.height >= 100.0;
        BOOL notHuge   = f.size.height <= ref.size.height * kMaxKeyboardFraction;
        BOOL bottomed  = fabs(CGRectGetMaxY(f) - CGRectGetMaxY(ref)) <= kBottomTolerance;

        if (wide && tallEnough && notHuge && bottomed) {
            // le plus HAUT sommet gagne : englobe les barres d'accessoires
            if (CGRectIsNull(*best) || CGRectGetMinY(f) < CGRectGetMinY(*best)) *best = f;
        }
        LKBFScan(sub, depth + 1, ref, cs, best);
    }
}

static CGRect LKBFRealKeyboardFrame(void) {
    UIWindowScene *ws = LKBFActiveScene();
    if (!ws) return CGRectNull;
    UIWindow *key = LKBFKeyWindow(ws);
    CGRect ref = ws.coordinateSpace.bounds;
    if (ref.size.height <= 0) return CGRectNull;

    CGRect best = CGRectNull;
    for (UIWindow *w in ws.windows) {
        if (w == key || w.hidden || w.alpha < 0.01) continue;
        LKBFScan(w, 0, ref, ws.coordinateSpace, &best);
    }
    return best;
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
            gHUD.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
            gHUD.textColor = UIColor.whiteColor;
            gHUD.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.80];
            gHUD.userInteractionEnabled = NO;
            gHUD.layer.zPosition = 9999;
            [key addSubview:gHUD];
        }
        gHUD.text = text;
        gHUD.frame = CGRectMake(2, key.safeAreaInsets.top,
                                key.bounds.size.width - 4, 84);
        [key bringSubviewToFront:gHUD];
    });
}

#pragma mark - Sauvetage de l'accessoire (désactivé par défaut)

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
    CGRect real  = LKBFRealKeyboardFrame();
    NSString *verdict = @"—";

    BOOL hiding = [name isEqualToString:UIKeyboardWillHideNotification] ||
                  [name isEqualToString:UIKeyboardDidHideNotification];

    if (hiding) {
        fixed.size.width  = ref.size.width;
        if (fixed.size.height <= 0) fixed.size.height = 300;
        fixed.origin.x = CGRectGetMinX(ref);
        fixed.origin.y = CGRectGetMaxY(ref);
        gKeyboardTop = -1;
        verdict = @"hide";
    } else if (CGRectIsNull(real) || real.size.height <= 0) {
        verdict = @"pas de mesure";        // on ne touche à rien
    } else {
        fixed = real;
        CGFloat lift = LKBFNumber(@"LKBF_Lift", kLiftDefault);
        fixed.origin.y    -= lift;
        fixed.size.height += lift;
        fixed.origin.x    = CGRectGetMinX(ref);
        fixed.size.width  = ref.size.width;

        // ---- GARDE-FOUS : une frame aberrante est jetée, pas injectée ----
        BOOL sane = fixed.size.height >= 80.0
                 && fixed.size.height <= ref.size.height * kMaxKeyboardFraction
                 && fixed.origin.y    >= CGRectGetMinY(ref) + ref.size.height * 0.20
                 && fixed.origin.y    <= CGRectGetMaxY(ref);
        if (!sane) {
            fixed = given;
            verdict = @"REJETE";
        } else {
            gKeyboardTop = fixed.origin.y;
            verdict = @"ok";
        }
    }

    LKBFHUD([NSString stringWithFormat:
             @"%@ [%@]\nsys  h=%.0f y=%.0f\nreal h=%.0f y=%.0f\nfix  h=%.0f y=%.0f",
             [name stringByReplacingOccurrencesOfString:@"Notification" withString:@""],
             verdict,
             given.size.height, given.origin.y,
             CGRectIsNull(real) ? -1 : real.size.height,
             CGRectIsNull(real) ? -1 : real.origin.y,
             fixed.size.height, fixed.origin.y]);

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
        NSLog(@"[LegacyKBFix] v0.4 chargé");
    }
}
