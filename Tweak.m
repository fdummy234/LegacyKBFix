//
//  LegacyKBFix — Tweak.m  (v0.2)
//
//  Symptôme visé : composer sur deux rangées (champ de texte + barre Aa/photo/Send).
//  Le clavier monte, l'app remonte le composer d'un cran trop court, la rangée
//  du bas passe sous le clavier.
//
//  Deux causes possibles, traitées toutes les deux :
//    (A) la frame de clavier annoncée dans les notifications UIKeyboard* sous-estime
//        la hauteur réellement occupée → on la corrige avant que l'app la lise.
//    (B) la rangée du bas est un inputAccessoryView, et UIKit ne le positionne plus
//        correctement depuis iOS 26 → on le remonte au-dessus du clavier.
//
//  Aucune dépendance à Substrate / ellekit : swizzling ObjC pur.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - ==== RÉGLAGES (modifie ici, puis rebuild) ====

static BOOL    kRepairDefault    = YES;   // (A) corriger la frame des notifications
static BOOL    kAccessoryDefault = YES;   // (B) remonter l'inputAccessoryView
static BOOL    kHUDDefault       = YES;   // overlay de diagnostic — mets NO quand c'est réglé
static CGFloat kLiftDefault      = 0.0;   // points ajoutés à la hauteur du clavier.
                                          // Si tout le reste échoue, monte ça jusqu'à ce
                                          // que Send réapparaisse (commence par 50).

// Surchargeables via NSUserDefaults si tu peux écrire dans les prefs de l'app :
// LKBF_Repair / LKBF_Accessory / LKBF_HUD / LKBF_Lift.

static BOOL LKBFFlag(NSString *key, BOOL fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static CGFloat LKBFNumber(NSString *key, CGFloat fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? (CGFloat)[v doubleValue] : fallback;
}

#pragma mark - Helpers scène / hiérarchie

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

static UIView *LKBFFindClass(UIView *root, NSString *name) {
    for (UIView *v in root.subviews) {
        if ([NSStringFromClass(v.class) isEqualToString:name]) return v;
        UIView *hit = LKBFFindClass(v, name);
        if (hit) return hit;
    }
    return nil;
}

static UIView *LKBFFirstResponder(UIView *root) {
    if (root.isFirstResponder) return root;
    for (UIView *v in root.subviews) {
        UIView *hit = LKBFFirstResponder(v);
        if (hit) return hit;
    }
    return nil;
}

// Frame réellement occupée par le clavier, dans l'espace de coordonnées de la scène.
// CGRectNull si aucun clavier visible.
static CGRect LKBFRealKeyboardFrame(void) {
    UIWindowScene *ws = LKBFActiveScene();
    if (!ws) return CGRectNull;

    CGRect best = CGRectNull;
    for (UIWindow *w in ws.windows) {
        NSString *cls = NSStringFromClass(w.class);
        if (![cls containsString:@"KeyboardWindow"] &&
            ![cls containsString:@"TextEffectsWindow"]) continue;

        UIView *host = LKBFFindClass(w, @"UIInputSetHostView");
        if (!host || host.hidden || host.bounds.size.height <= 0) continue;

        CGRect f = [host convertRect:host.bounds toCoordinateSpace:ws.coordinateSpace];
        if (f.size.height <= 0) continue;
        if (CGRectIsNull(best) || CGRectGetMinY(f) < CGRectGetMinY(best)) best = f;
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
            gHUD.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.75];
            gHUD.userInteractionEnabled = NO;
            gHUD.layer.zPosition = 9999;
            [key addSubview:gHUD];
        }
        gHUD.text = text;
        gHUD.frame = CGRectMake(4, key.safeAreaInsets.top,
                                key.bounds.size.width - 8, 76);
        [key bringSubviewToFront:gHUD];
    });
}

#pragma mark - (B) Sauvetage de l'inputAccessoryView

static void LKBFRescueAccessory(void) {
    if (!LKBFFlag(@"LKBF_Accessory", kAccessoryDefault)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *ws = LKBFActiveScene();
        if (!ws) return;
        CGRect kb = LKBFRealKeyboardFrame();
        if (CGRectIsNull(kb) || kb.size.height <= 0) return;

        UIWindow *key = LKBFKeyWindow(ws);
        UIView *fr = key ? LKBFFirstResponder(key) : nil;
        UIView *acc = fr.inputAccessoryView;
        if (!acc || acc.hidden || acc.bounds.size.height <= 0) return;

        CGRect accRect = [acc convertRect:acc.bounds toCoordinateSpace:ws.coordinateSpace];
        CGFloat overlap = CGRectGetMaxY(accRect) - CGRectGetMinY(kb);
        if (overlap <= 0.5) return;   // déjà bien placé

        // La mesure inclut la transform courante, donc réappliquer converge.
        acc.transform = CGAffineTransformTranslate(acc.transform, 0, -overlap);
    });
}

#pragma mark - (A) Correction du userInfo

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
    CGRect real  = LKBFRealKeyboardFrame();
    CGRect fixed = given;

    BOOL hiding = [name isEqualToString:UIKeyboardWillHideNotification] ||
                  [name isEqualToString:UIKeyboardDidHideNotification];

    if (hiding) {
        fixed.size.width = ref.size.width;
        if (fixed.size.height <= 0) fixed.size.height = 300;
        fixed.origin.x = CGRectGetMinX(ref);
        fixed.origin.y = CGRectGetMaxY(ref);
    } else if (!CGRectIsNull(real) && real.size.height > 0) {
        fixed = real;

        CGFloat lift = LKBFNumber(@"LKBF_Lift", kLiftDefault);
        fixed.origin.y    -= lift;
        fixed.size.height += lift;

        fixed.origin.x   = CGRectGetMinX(ref);
        fixed.size.width = ref.size.width;
        if (fixed.origin.y < CGRectGetMinY(ref) || fixed.origin.y > CGRectGetMaxY(ref))
            fixed.origin.y = CGRectGetMaxY(ref) - fixed.size.height;
    }

    // --- diagnostic ---
    UIWindow *key = ws ? LKBFKeyWindow(ws) : nil;
    UIView *fr = key ? LKBFFirstResponder(key) : nil;
    UIView *acc = fr.inputAccessoryView;
    LKBFHUD([NSString stringWithFormat:
             @"%@\nsys  h=%.0f y=%.0f\nreal h=%.0f y=%.0f\nfix  h=%.0f y=%.0f\nFR=%@ acc=%@ h=%.0f",
             [name stringByReplacingOccurrencesOfString:@"Notification" withString:@""],
             given.size.height, given.origin.y,
             CGRectIsNull(real) ? -1 : real.size.height,
             CGRectIsNull(real) ? -1 : real.origin.y,
             fixed.size.height, fixed.origin.y,
             fr ? NSStringFromClass(fr.class) : @"(nil)",
             acc ? NSStringFromClass(acc.class) : @"(nil)",
             acc ? acc.bounds.size.height : 0]);

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
    if ([name isEqualToString:UIKeyboardDidShowNotification] ||
        [name isEqualToString:UIKeyboardDidChangeFrameNotification]) {
        LKBFRescueAccessory();
    }
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
        NSLog(@"[LegacyKBFix] v0.2 chargé");
    }
}
