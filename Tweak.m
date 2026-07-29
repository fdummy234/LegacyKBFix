//
//  LegacyKBFix — Tweak.m  (v1.3 — build final)
//
//  ── PROBLÈME ────────────────────────────────────────────────────────────────
//  iOS 27, app de chat bâtie sur Chatto (Badoo).
//
//  Les vues de l'app vivent dans un espace de coordonnées de 896 pt de haut,
//  alors que les notifications UIKeyboard* annoncent la frame du clavier dans un
//  espace de 956 pt. Mesures relevées sur device :
//
//      vrai clavier     UIKeyboardItemContainerView   y=598  h=298   (bas = 896)
//      frame annoncée   notification UIKeyboard*      y=636  h=320   (bas = 956)
//
//  Chatto plaçait donc sa ChatInputBar par rapport à 636 au lieu de 598, soit
//  38 pt trop bas : la rangée Aa/photo/Send passait sous le clavier, et il
//  fallait fermer le clavier pour pouvoir envoyer un message.
//
//  ── CORRECTIF ───────────────────────────────────────────────────────────────
//  Intercepter les notifications clavier et remplacer UIKeyboardFrameBegin/End
//  par la vraie frame, mesurée dans la hiérarchie de vues et donc exprimée dans
//  l'espace de coordonnées de la scène. L'app refait ensuite ses calculs
//  habituels, avec des chiffres cohérents entre eux.
//
//  Le clavier iOS 27 est flottant : son fond gris commence quelques points sous
//  son conteneur. kLift compense, pour équilibrer les blancs au-dessus et en
//  dessous de la rangée Send.
//
//  ── POURQUOI PAR GÉOMÉTRIE ET NON PAR NOM DE CLASSE ─────────────────────────
//  UIInputSetHostView n'existe plus sur iOS 27 ; chercher un nom précis échoue
//  silencieusement. La hiérarchie observée est désormais :
//
//      UITextEffectsWindow
//        └─ UITrackingWindowView            y=0    h=896   (plein écran)
//             ├─ UIKeyboardItemContainerView y=598  h=298   ← le clavier
//             │    └─ UIRemoteKeyboardPlaceholderView
//             └─ UIEditingOverlayGestureView y=0    h=896   (plein écran)
//
//  Un candidat doit donc être pleine largeur, ancré au BAS de la scène, et d'une
//  hauteur crédible. Sans le critère d'ancrage, on retient UITrackingWindowView
//  (plein écran) et l'app se retrouve avec sa barre de saisie hors écran.
//
//  Toute frame aberrante est jetée : on laisse alors passer celle du système, ce
//  qui ramène au bug d'origine mais jamais à une interface cassée.
//
//  ── DÉPENDANCES ─────────────────────────────────────────────────────────────
//  Aucune. Swizzling ObjC pur, ni Substrate ni ellekit : chargeable dans une app
//  sideloadée sans jailbreak.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Réglages

// Décalage vertical de la barre de saisie, en points.
// Positif = remonte la barre (agrandit le blanc entre Send et le clavier).
static const CGFloat kLift = 10.0;

// Garde-fous
static const CGFloat kMaxKeyboardFraction = 0.70;  // hauteur max d'un clavier crédible
static const CGFloat kMinKeyboardHeight   = 100.0; // hauteur min d'un candidat
static const CGFloat kMinFixedHeight      = 80.0;  // hauteur min d'une frame injectable
static const CGFloat kMinWidthFraction    = 0.80;  // largeur min d'un candidat
static const CGFloat kBottomTolerance     = 6.0;   // marge d'ancrage au bas de l'écran
static const CGFloat kMinTopFraction      = 0.20;  // sommet min d'une frame injectable
static const int     kMaxScanDepth        = 6;

#pragma mark - Scène

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

#pragma mark - Mesure du clavier

static void LKBFScan(UIView *v, int depth, CGRect ref,
                     id<UICoordinateSpace> cs, CGRect *best) {
    if (depth > kMaxScanDepth) return;
    for (UIView *sub in v.subviews) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        CGRect f = [sub convertRect:sub.bounds toCoordinateSpace:cs];

        BOOL wide       = f.size.width  >= ref.size.width * kMinWidthFraction;
        BOOL tallEnough = f.size.height >= kMinKeyboardHeight;
        BOOL notHuge    = f.size.height <= ref.size.height * kMaxKeyboardFraction;
        BOOL bottomed   = fabs(CGRectGetMaxY(f) - CGRectGetMaxY(ref)) <= kBottomTolerance;

        if (wide && tallEnough && notHuge && bottomed) {
            // le sommet le plus haut gagne : englobe d'éventuelles barres d'accessoires
            if (CGRectIsNull(*best) || CGRectGetMinY(f) < CGRectGetMinY(*best)) *best = f;
        }
        LKBFScan(sub, depth + 1, ref, cs, best);
    }
}

static CGRect LKBFRealKeyboardFrame(void) {
    UIWindowScene *ws = LKBFActiveScene();
    if (!ws) return CGRectNull;
    CGRect ref = ws.coordinateSpace.bounds;
    if (ref.size.height <= 0) return CGRectNull;

    UIWindow *key = LKBFKeyWindow(ws);
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

    CGRect f = real;
    f.origin.y    -= kLift;
    f.size.height += kLift;
    f.origin.x     = CGRectGetMinX(ref);
    f.size.width   = ref.size.width;

    BOOL sane = f.size.height >= kMinFixedHeight
             && f.size.height <= ref.size.height * kMaxKeyboardFraction
             && f.origin.y    >= CGRectGetMinY(ref) + ref.size.height * kMinTopFraction
             && f.origin.y    <= CGRectGetMaxY(ref);
    return sane ? f : CGRectNull;
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

    BOOL hiding = [name isEqualToString:UIKeyboardWillHideNotification] ||
                  [name isEqualToString:UIKeyboardDidHideNotification];

    if (hiding) {
        // clavier qui part : frame pleine largeur, entièrement hors écran
        fixed.size.width = ref.size.width;
        if (fixed.size.height <= 0) fixed.size.height = 300;
        fixed.origin.x = CGRectGetMinX(ref);
        fixed.origin.y = CGRectGetMaxY(ref);
    } else {
        CGRect computed = LKBFComputeFixed(ref);
        if (CGRectIsNull(computed)) return info;   // rien de fiable : on ne touche à rien
        fixed = computed;
    }

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

#pragma mark - Swizzles

static void (*orig_postName)(id, SEL, NSString *, id, NSDictionary *);
static void my_postName(id self, SEL _cmd, NSString *name, id object, NSDictionary *info) {
    if (LKBFIsKeyboardNote(name)) info = LKBFRepair(name, info);
    orig_postName(self, _cmd, name, object, info);
}

static void (*orig_postNote)(id, SEL, NSNotification *);
static void my_postNote(id self, SEL _cmd, NSNotification *n) {
    if (LKBFIsKeyboardNote(n.name)) {
        NSDictionary *fixed = LKBFRepair(n.name, n.userInfo);
        if (fixed != n.userInfo)
            n = [NSNotification notificationWithName:n.name object:n.object userInfo:fixed];
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
    }
}
