//
//  LegacyKBFix — Tweak.m  (v1.2)
//
//  DIAGNOSTIC ÉTABLI (iOS 27, app Chatto/Badoo) :
//
//    vrai clavier    UIKeyboardItemContainerView   y=598  h=298   (bas = 896)
//    frame annoncée  notification UIKeyboard*      y=636  h=320   (bas = 956)
//
//    Les vues de l'app vivent dans un espace de 896 de haut ; la notification est
//    exprimée dans un espace de 956. Chatto plaçait donc sa ChatInputBar par rapport
//    à 636 au lieu de 598 → 38 pt trop bas → rangée Aa/Send sous le clavier.
//
//  CORRECTIF : remplacer la frame de la notification par la vraie mesure, prise
//  dans l'espace de coordonnées de la scène.
//
//  v1.1 : le clavier iOS 27 est flottant — son fond gris commence quelques points
//  sous son conteneur, d'où un vide résiduel entre la barre et le clavier. kLift
//  compense. RÉGLEUR LIVE : glisser à DEUX DOIGTS ajuste kLift en direct et le
//  sauvegarde, sans rebuild.
//
//  Aucune dépendance à Substrate / ellekit : swizzling ObjC pur.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - ==== RÉGLAGES ====

static BOOL    kRepairDefault    = YES;
static BOOL    kAccessoryDefault = NO;    // ne pas toucher au KeyboardTrackingView
static BOOL    kHUDDefault       = NO;    // microscope
static BOOL    kTunerDefault     = YES;   // régleur 2 doigts — NO pour le build final
static CGFloat kLiftDefault      = 10.0;  // + remonte la barre (agrandit le blanc du bas)

// Garde-fous
static const CGFloat kMaxKeyboardFraction = 0.70;
static const CGFloat kBottomTolerance     = 6.0;
static const CGFloat kLiftMin             = -80.0;
static const CGFloat kLiftMax             = 120.0;

static BOOL LKBFFlag(NSString *key, BOOL fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static CGFloat LKBFNumber(NSString *key, CGFloat fallback) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? (CGFloat)[v doubleValue] : fallback;
}
static CGFloat LKBFLift(void) {
    CGFloat l = LKBFNumber(@"LKBF_Lift", kLiftDefault);
    return MAX(kLiftMin, MIN(kLiftMax, l));
}

// Implémentations originales — déclarées ici, le régleur en a besoin.
static void (*orig_postName)(id, SEL, NSString *, id, NSDictionary *);
static void (*orig_postNote)(id, SEL, NSNotification *);

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

// Un candidat doit être pleine largeur, ancré au BAS de la scène, et d'une hauteur
// crédible. Ça élimine UITrackingWindowView et UIEditingOverlayGestureView.
static void LKBFScan(UIView *v, int depth, CGRect ref,
                     id<UICoordinateSpace> cs, CGRect *best) {
    if (depth > 6) return;
    for (UIView *sub in v.subviews) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        CGRect f = [sub convertRect:sub.bounds toCoordinateSpace:cs];

        BOOL wide       = f.size.width  >= ref.size.width * 0.80;
        BOOL tallEnough = f.size.height >= 100.0;
        BOOL notHuge    = f.size.height <= ref.size.height * kMaxKeyboardFraction;
        BOOL bottomed   = fabs(CGRectGetMaxY(f) - CGRectGetMaxY(ref)) <= kBottomTolerance;

        if (wide && tallEnough && notHuge && bottomed) {
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

// Frame corrigée prête à injecter, ou CGRectNull si rien de crédible.
static CGRect LKBFComputeFixed(CGRect ref) {
    CGRect real = LKBFRealKeyboardFrame();
    if (CGRectIsNull(real) || real.size.height <= 0) return CGRectNull;

    CGFloat lift = LKBFLift();
    CGRect f = real;
    f.origin.y    -= lift;
    f.size.height += lift;
    f.origin.x     = CGRectGetMinX(ref);
    f.size.width   = ref.size.width;

    BOOL sane = f.size.height >= 80.0
             && f.size.height <= ref.size.height * kMaxKeyboardFraction
             && f.origin.y    >= CGRectGetMinY(ref) + ref.size.height * 0.20
             && f.origin.y    <= CGRectGetMaxY(ref);
    return sane ? f : CGRectNull;
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

#pragma mark - Relance du layout (utilisée par le régleur)

// Repost d'une paire de notifications de changement de frame, en passant par
// l'implémentation ORIGINALE : la valeur est déjà corrigée, pas de double passe.
static void LKBFNudge(void) {
    UIWindowScene *ws = LKBFActiveScene();
    if (!ws) return;
    CGRect ref = ws.coordinateSpace.bounds;
    CGRect f = LKBFComputeFixed(ref);
    if (CGRectIsNull(f)) return;

    NSValue *val = [NSValue valueWithCGRect:f];
    NSDictionary *ui = @{
        UIKeyboardFrameBeginUserInfoKey        : val,
        UIKeyboardFrameEndUserInfoKey          : val,
        UIKeyboardAnimationDurationUserInfoKey : @(0.0),
        UIKeyboardAnimationCurveUserInfoKey    : @(UIViewAnimationCurveLinear),
        UIKeyboardIsLocalUserInfoKey           : @YES,
    };
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    SEL sel = @selector(postNotificationName:object:userInfo:);
    if (!orig_postName) return;
    orig_postName(nc, sel, UIKeyboardWillChangeFrameNotification, nil, ui);
    orig_postName(nc, sel, UIKeyboardDidChangeFrameNotification,  nil, ui);
}

#pragma mark - Régleur live (glisser à deux doigts)

static UILabel *gTunerLabel;
static CGFloat  gLiftBase = 0;
static NSUInteger gTunerGen = 0;

static void LKBFTunerLabel(NSString *text, BOOL autoHide) {
    UIWindowScene *ws = LKBFActiveScene();
    UIWindow *key = ws ? LKBFKeyWindow(ws) : nil;
    if (!key) return;

    if (!gTunerLabel || gTunerLabel.window != key) {
        gTunerLabel = [UILabel new];
        gTunerLabel.textAlignment = NSTextAlignmentCenter;
        gTunerLabel.font = [UIFont monospacedDigitSystemFontOfSize:15
                                                            weight:UIFontWeightSemibold];
        gTunerLabel.textColor = UIColor.whiteColor;
        gTunerLabel.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.80];
        gTunerLabel.layer.cornerRadius = 9;
        gTunerLabel.clipsToBounds = YES;
        gTunerLabel.userInteractionEnabled = NO;
        gTunerLabel.layer.zPosition = 10000;
        [key addSubview:gTunerLabel];
    }
    gTunerLabel.text = text;
    gTunerLabel.alpha = 1;
    gTunerLabel.hidden = NO;
    gTunerLabel.frame = CGRectMake((key.bounds.size.width - 150) / 2,
                                   key.safeAreaInsets.top + 8, 150, 32);
    [key bringSubviewToFront:gTunerLabel];

    if (autoHide) {
        NSUInteger gen = ++gTunerGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gen != gTunerGen) return;
            [UIView animateWithDuration:0.3 animations:^{ gTunerLabel.alpha = 0; }];
        });
    }
}

@interface LKBFTuner : NSObject
+ (instancetype)shared;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

@implementation LKBFTuner

+ (instancetype)shared {
    static LKBFTuner *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LKBFTuner new]; });
    return s;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) gLiftBase = LKBFLift();

    CGFloat dy = [g translationInView:g.view].y;
    // vers le HAUT = remonter la barre
    CGFloat lift = roundf(gLiftBase - dy / 2.0f);
    lift = MAX(kLiftMin, MIN(kLiftMax, lift));

    [NSUserDefaults.standardUserDefaults setDouble:lift forKey:@"LKBF_Lift"];

    BOOL ended = (g.state == UIGestureRecognizerStateEnded ||
                  g.state == UIGestureRecognizerStateCancelled);
    LKBFTunerLabel([NSString stringWithFormat:@"lift  %+.0f", lift], ended);
    LKBFNudge();
}

@end

static void LKBFInstallTuner(void) {
    if (!LKBFFlag(@"LKBF_Tuner", kTunerDefault)) return;
    UIWindowScene *ws = LKBFActiveScene();
    UIWindow *key = ws ? LKBFKeyWindow(ws) : nil;
    if (!key) return;

    for (UIGestureRecognizer *g in key.gestureRecognizers)
        if ([g isKindOfClass:UIPanGestureRecognizer.class] &&
            [g.name isEqualToString:@"LKBFTunerPan"]) return;   // déjà posé

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:[LKBFTuner shared]
                                                action:@selector(pan:)];
    pan.name = @"LKBFTunerPan";
    pan.minimumNumberOfTouches = 2;
    pan.maximumNumberOfTouches = 2;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    [key addGestureRecognizer:pan];
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
    NSString *verdict = @"—";

    BOOL hiding = [name isEqualToString:UIKeyboardWillHideNotification] ||
                  [name isEqualToString:UIKeyboardDidHideNotification];

    if (hiding) {
        fixed.size.width = ref.size.width;
        if (fixed.size.height <= 0) fixed.size.height = 300;
        fixed.origin.x = CGRectGetMinX(ref);
        fixed.origin.y = CGRectGetMaxY(ref);
        gKeyboardTop = -1;
        verdict = @"hide";
    } else {
        CGRect computed = LKBFComputeFixed(ref);
        if (CGRectIsNull(computed)) {
            verdict = @"REJETE";           // on laisse passer celle du système
        } else {
            fixed = computed;
            gKeyboardTop = fixed.origin.y;
            verdict = @"ok";
        }
    }

    LKBFHUD([NSString stringWithFormat:
             @"%@ [%@] lift=%+.0f\nsys h=%.0f y=%.0f\nfix h=%.0f y=%.0f",
             [name stringByReplacingOccurrencesOfString:@"Notification" withString:@""],
             verdict, LKBFLift(),
             given.size.height, given.origin.y,
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
    if ([name containsString:@"DidShow"] || [name containsString:@"DidChangeFrame"]) {
        LKBFRescueAccessory();
        dispatch_async(dispatch_get_main_queue(), ^{ LKBFInstallTuner(); });
    }
}

#pragma mark - Swizzles

static void my_postName(id self, SEL _cmd, NSString *name, id object, NSDictionary *info) {
    if (LKBFIsKeyboardNote(name)) {
        orig_postName(self, _cmd, name, object, LKBFRepair(name, info));
        LKBFAfterNote(name);
        return;
    }
    orig_postName(self, _cmd, name, object, info);
}

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
        NSLog(@"[LegacyKBFix] v1.2 chargé");
    }
}
