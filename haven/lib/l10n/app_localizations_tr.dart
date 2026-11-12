// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Turkish (`tr`).
class AppLocalizationsTr extends AppLocalizations {
  AppLocalizationsTr([String locale = 'tr']) : super(locale);

  @override
  String get appearanceTitle => 'Görünüm';

  @override
  String get appearanceThemeHeader => 'Tema';

  @override
  String get appearanceThemeSystem => 'Sistem varsayılanı';

  @override
  String get appearanceThemeSystemSubtitle => 'Cihaz ayarlarınızla eşleşir';

  @override
  String get appearanceThemeLight => 'Açık';

  @override
  String get appearanceThemeLightSubtitle => 'Her zaman açık temayı kullan';

  @override
  String get appearanceThemeDark => 'Koyu';

  @override
  String get appearanceThemeDarkSubtitle => 'Her zaman koyu temayı kullan';

  @override
  String get appearanceLanguageTitle => 'Dil';

  @override
  String get languageSystemDefault => 'Sistem varsayılanı';

  @override
  String get commonTryAgain => 'Tekrar Dene';

  @override
  String get commonDismiss => 'Kapat';

  @override
  String get commonSettings => 'Ayarlar';

  @override
  String get commonInvitations => 'Davetler';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString bekleyen davet',
      one: '1 bekleyen davet',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Geri';

  @override
  String get commonContinue => 'Devam Et';

  @override
  String get commonSkip => 'Atla';

  @override
  String get commonRetry => 'Yeniden Dene';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString adımdan $currentString. adım';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Gizli ve sansüre dirençli konum paylaşımı.';

  @override
  String get onboardingWelcomeCta => 'Başla';

  @override
  String get onboardingValueProp1Title =>
      'Sizi yalnızca çevreleriniz görebilir';

  @override
  String get onboardingValueProp2Title => 'Kimse kapatamaz';

  @override
  String get onboardingValueProp3Title => 'Hesaba gerek yok';

  @override
  String get onboardingValueProp1Summary =>
      'Cihazınızda şifrelenir; yalnızca seçtiğiniz çevreler okuyabilir. Onu taşıyan aktarıcılar bile okuyamaz.';

  @override
  String get onboardingValueProp2Summary =>
      'Merkezi sunucu yok. Bağımsız aktarıcılar üzerinde çalışır. Onları pek çok kişi işletir, bu yüzden hiçbir şirket kapatamaz.';

  @override
  String get onboardingValueProp3Summary =>
      'E-posta, telefon veya kayıt yok. Gizli anahtarınız telefonunuzdan hiç çıkmaz. Haven\'in seçtiği anonim adı koruyun ya da kendi adınızı seçin.';

  @override
  String get onboardingCreateIdentityTitle => 'Kimliğinizi oluşturun';

  @override
  String get onboardingCreateIdentityCta => 'Kimliğimi Oluştur';

  @override
  String get onboardingCreateIdentityLoading => 'Hazırlanıyor…';

  @override
  String get onboardingCreateIdentityImportPrompt =>
      'Zaten bir anahtarınız var mı?';

  @override
  String get onboardingCreateIdentityImportLink => 'Onun yerine içe aktarın';

  @override
  String get onboardingCreateIdentityError =>
      'Kimliğiniz oluşturulurken bir sorun oluştu. Lütfen tekrar deneyin.';

  @override
  String get onboardingImportTitle => 'Mevcut anahtarınızı içe aktarın';

  @override
  String get onboardingImportBody =>
      'Haven uyumlu başka bir uygulamadan yedeklediğiniz gizli anahtarı yapıştırın.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'İçe Aktar';

  @override
  String get onboardingImportLoading => 'İçe aktarılıyor…';

  @override
  String get onboardingImportInvalid =>
      'Bu geçerli bir yedek anahtara benzemiyor. Lütfen kontrol edip tekrar deneyin.';

  @override
  String get onboardingImportError =>
      'Bu anahtarı içe aktaramadık. Lütfen kontrol edip tekrar deneyin.';

  @override
  String get onboardingDisplayNameHint => 'örn. Ali';

  @override
  String get onboardingDisplayNameError =>
      'Bu ad kaydedilemedi. Lütfen tekrar deneyin.';

  @override
  String get onboardingAddPhotoOptional => 'Fotoğraf ekle (isteğe bağlı)';

  @override
  String get commonCancel => 'İptal';

  @override
  String get commonOpenSettings => 'Ayarları aç';

  @override
  String get settingsTitle => 'Ayarlar';

  @override
  String get settingsIdentityTitle => 'Kimlik';

  @override
  String get settingsRelaysTitle => 'Aktarıcılar';

  @override
  String get settingsLocationTitle => 'Konum';

  @override
  String get settingsLocationSubtitleOn => 'Arka planda paylaşım açık';

  @override
  String get settingsLocationSubtitleOff => 'Yalnızca Haven açıkken';

  @override
  String get settingsMapStyleTitle => 'Harita stili';

  @override
  String get settingsAboutTitle => 'Hakkında';

  @override
  String get settingsHowItWorksTitle => 'How It Works';

  @override
  String get settingsDebugOverlayTitle => 'Hata Ayıklama Günlüğü Katmanı';

  @override
  String get settingsDebugOverlaySubtitle => 'Günlük çıktısını ekranda göster';

  @override
  String get relaySettingsTitle => 'Aktarıcılar';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Aktarıcıları denetle';

  @override
  String get relaySettingsNoIdentityTitle => 'Kimlik Yok';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Aktarıcıları yönetmek için önce bir kimlik oluşturun.';

  @override
  String get relaySettingsLoadIdentityError => 'Kimlik yüklenemedi.';

  @override
  String get relaySettingsInboxTitle => 'Gelen Kutusu Aktarıcılarım';

  @override
  String get relaySettingsInboxSubtitle =>
      'kind 10050, davetlerin size ulaştığı yer';

  @override
  String get relaySettingsKeyPackageTitle => 'KeyPackage Aktarıcılarım';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10002, sizi davet etmek için gereken anahtarları başkalarının bulduğu yer';

  @override
  String get relaySettingsProfileTitle => 'Profil Aktarıcılarım';

  @override
  String get relaySettingsProfileSubtitle =>
      'kind 0, herkese açık profilinizin sorgulandığı ve yayımlandığı yer — bu aktarıcılar diğer aktarıcılarınızdan ayrı tutulur ve profil aktarıcılarınızın listesi hiçbir zaman yayımlanmaz';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'Profil sorguları duraklatıldı';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'Geriye çok az Profil aktarıcısı kaldı; bu nedenle üyelerin adları ve fotoğrafları artık güncellenmeyecek.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Varsayılan profil aktarıcılarını geri yükle';

  @override
  String get relaySettingsLoadRelaysError => 'Aktarıcılar yüklenemedi.';

  @override
  String get relaySettingsAddRelay => 'Aktarıcı ekle';

  @override
  String get relaySettingsRestoreDefaults => 'Varsayılanları geri yükle';

  @override
  String get relaySettingsAddRelayError => 'Aktarıcı eklenemedi.';

  @override
  String get relaySettingsRemoveRelayError => 'Aktarıcı kaldırılamadı.';

  @override
  String get relaySettingsRestoreTitle =>
      'Varsayılan aktarıcılar geri yüklensin mi?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Mevcut $countString aktarıcınız Haven\'ın varsayılanlarıyla değiştirilecek. Bu işlem geri alınamaz.',
      one:
          'Mevcut 1 aktarıcınız Haven\'ın varsayılanlarıyla değiştirilecek. Bu işlem geri alınamaz.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Geri Yükle';

  @override
  String get relaySettingsRestoreSuccess => 'Varsayılanlar geri yüklendi.';

  @override
  String get relaySettingsRestoreError => 'Varsayılanlar geri yüklenemedi.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return '$url adresini kaldır';
  }

  @override
  String get relaySettingsStatusConnected => 'Bağlı';

  @override
  String get relaySettingsStatusChecking => 'Denetleniyor';

  @override
  String get relaySettingsStatusUnreachable => 'Ulaşılamıyor';

  @override
  String get relaySettingsStatusNotChecked => 'Denetlenmedi';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'Aktarıcı durumu: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'Yapılandırılmış aktarıcı yok';

  @override
  String get relaySettingsEmptyMessage =>
      'Başkalarının size ulaşabilmesi için en az bir aktarıcıya ihtiyacınız var. Haven varsayılanlarını geri yüklemek için aşağıya dokunun.';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'Diğer Haven trafiğinizi de taşıyor';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Uyarı: $url diğer Haven trafiğinizi de taşıyor; bu nedenle bu aktarıcı profilinizi o trafikle ilişkilendirebilir';
  }

  @override
  String get locationSettingsTitle => 'Konum';

  @override
  String get locationSettingsDisabledSnack => 'Arka planda paylaşım kapatıldı';

  @override
  String get locationSettingsEnabledSnack => 'Arka planda paylaşım açıldı';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'Android\'in çalışır tutması için arka planda paylaşımın bir bildirime ihtiyacı var. Şimdilik kapalı. Açmak için Haven\'ın bildirimlerine izin verin.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'Açık. Bazı telefonlarda pil optimizasyonu paylaşımı duraklatabilir. Güvenilir kalması için Haven\'ı pil optimizasyonundan hariç tutun.';

  @override
  String get locationSettingsBatteryOptNote =>
      'Haven için pil optimizasyonu hâlâ açık. Bazı telefonlar, arka planda paylaşımı uyarmadan durdurmak için bu ayarı kullanır. Paylaşımın güvenilir kalması için Haven\'ı hariç tutun.';

  @override
  String get locationSettingsErrorSnack => 'Bir sorun oluştu';

  @override
  String get locationSettingsIntro =>
      'Haven, uygulama açık olduğu sürece konumunuzu çevrelerinizle paylaşır. Bunu açarsanız Haven arka plandayken de çevreleriniz konumunuzu görmeye devam eder. Sistem Haven\'ı kapatırsa kendi paylaşımınız durur: Haven yine de çevrelerinizin konumlarını almak için uyanabilir, ama sizinkini göndermek için asla uyanmaz. Android\'de paylaşım, Haven\'ı son kullanılanlar listesinden kaydırıp çıkarsanız bile sürer ve telefon yeniden başlatıldıktan sonra kendiliğinden tekrar çalışmaya başlar. iPhone\'da ise paylaşım, siz Haven\'ı açana kadar durmuş olarak kalır.';

  @override
  String get locationSettingsToggleTitle => 'Arka planda paylaş';

  @override
  String get locationSettingsToggleSubtitle =>
      'Haven arka planda çalışırken paylaşmaya devam et';

  @override
  String get locationSettingsIosLimitedNote =>
      'Paylaşım, mevcut izninizle arka planda çalışmaya devam eder ve bu sırada iOS, ekranın üst kısmında kendi mavi konum çubuğunu gösterir. Ayarlar\'da Haven için Konum\'u \"Her Zaman\" olarak ayarlayın; böylece Haven, iOS uygulamayı kapattıktan sonra çevrelerinizin konumlarını da sonradan yakalayabilir. \"Her Zaman\" seçiliyken iOS, mavi konum çubuğu yerine durum çubuğunda kendi konum ok simgesini gösterebilir. Kendi paylaşımınız ise Haven\'ı tekrar açtığınızda yeniden başlar.';

  @override
  String get locationSettingsAndroidHeader =>
      'Güvenilirlik için işletim sistemi ayarları';

  @override
  String get locationSettingsAndroidNotification =>
      'Android\'in arka plan hizmetini canlı tutması için Haven\'ın kalıcı bir bildirime ihtiyacı var. Bildirim iznini reddettiyseniz Ayarlar\'ı açıp Haven için bildirimlere izin verin.';

  @override
  String get locationSettingsAndroidBattery =>
      'Güvenilir arka plan paylaşımı için ayrıca Haven\'ı pil optimizasyonundan hariç tutun. Ayarlar → Uygulamalar → Haven → Pil → Her zaman izin ver yolunu izleyin.';

  @override
  String get locationSettingsAndroidVendors =>
      'Samsung cihazlarda Haven\'ı \"Uyuyan uygulamalar\" listesinden çıkarın (Cihaz bakımı → Pil → Arka plan kullanım sınırları). Xiaomi\'de ise Haven için Otomatik başlatmayı etkinleştirin.';

  @override
  String get locationSettingsIosGuidance =>
      'Arka planda paylaşım açıkken Haven bir konum oturumu sürdürür; böylece çevreleriniz sizi görmeye devam eder.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'iOS, Haven konumunuzu kullandığı sürece durum çubuğunda kendi konum ok simgesini gösterir; aynı simgeyi bir süre daha Konum Servisleri\'nde Haven\'ın yanında göstermeye devam eder.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'Konum izniniz \"Her Zaman\" olduğunda, Haven konumunuzu kullandığı sürece iOS ekranın üst kısmında kendi mavi konum çubuğunu gösterir.';

  @override
  String get locationDisclosureTitle => 'Konumunuzun paylaşımı';

  @override
  String get locationDisclosureWhy =>
      'Haven, canlı konumunuzu seçtiğiniz çevrelerdeki kişilere gösterir; onların konumunu da haritada size gösterir. Bunun için Haven\'ın, cihazınızın tam konumunu kullanma iznine ihtiyacı vardır.';

  @override
  String get locationDisclosureHow =>
      'Konumunuz cihazınızda uçtan uca şifrelenir; bu yüzden onu yalnızca seçtiğiniz çevrelerin üyeleri okuyabilir, Haven okuyamaz. Haven\'ın kendine ait bir sunucusu yoktur: şifreli güncellemeleriniz, başka insanların işlettiği bağımsız aktarıcılar üzerinden geçer; bu aktarıcılar ağ adresinizi görür, ama nerede olduğunuzu asla göremez. Haritayı çizmek için Haven, Stadia Maps\'ten sizin ve çevrenizin bulunduğu alanları ister; böylece Stadia Maps buranın kabaca neresi olduğunu öğrenir, ama adınızı, anahtarınızı ya da çevrelerinizde kimlerin olduğunu asla öğrenmez. Stadia Maps, kişisel bilgileri satmadığını veya takas etmediğini, cihazınıza çerez yerleştirmediğini ve sunucu günlüklerini yaklaşık iki hafta sakladığını belirtiyor; bu, onların kendi politikasıdır ve Haven bunun uygulanmasını sağlayamaz.';

  @override
  String get locationDisclosureSharing =>
      'Haven açıkken ve bir çevrede olduğunuz sürece konumunuz birkaç dakikada bir otomatik olarak gönderilir. Paylaşımı duraklatma seçeneği yoktur. Bir çevreyle paylaşımı durdurmak için o çevreden ayrılın.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'Bu uygulama, kapalıyken veya kullanılmadığında bile çevrelerinizle paylaşımı sağlamak için konum verilerini kullanır.';

  @override
  String get locationDisclosureBackgroundIos =>
      'Bu uygulama, Haven arka plandayken ve siz onu kullanmıyorken bile çevrelerinizle paylaşımı sağlamak için konum verilerini kullanır. iOS Haven\'ı kapatırsa, siz uygulamayı yeniden açana kadar paylaşım durur: Haven yine de çevrelerinizin konumlarını almak için uyanabilir, ama sizinkini göndermek için asla uyanmaz.';

  @override
  String get locationDisclosureManage =>
      'Arka planda paylaşımı istediğiniz zaman Ayarlar → Konum bölümünden kapatabilirsiniz.';

  @override
  String get locationDisclosureAgree => 'Kabul Et';

  @override
  String get locationDisclosureNotNow => 'Şimdi Değil';

  @override
  String get fgsNotificationSharing =>
      'Haven konum bilgisi gönderiyor ve alıyor';

  @override
  String get fgsNotificationPaused =>
      'Haven duraklatıldı — paylaşımı sürdürmek için uygulamayı açın';

  @override
  String get fgsNotificationOpen => 'Haven ekranda açık';

  @override
  String get fgsChannelName => 'Konum paylaşımı';

  @override
  String get fgsChannelDescription =>
      'Haven\'ın şifreli konumunuzu arka planda paylaşmaya devam etmesini sağlar.';

  @override
  String get mapStyleTitle => 'Harita stili';

  @override
  String get mapStyleMinimalTitle => 'Sade';

  @override
  String get mapStyleMinimalSubtitle =>
      'Açık ya da koyu temanızı izleyen sakin, az ayrıntılı bir tuval';

  @override
  String get mapStyleDetailedTitle => 'Ayrıntılı';

  @override
  String get mapStyleDetailedSubtitle =>
      'Tam renkli sokaklar, etiketler ve yerler';

  @override
  String get mapStyleOutdoorsTitle => 'Doğa';

  @override
  String get mapStyleOutdoorsSubtitle =>
      'Patika ve parklarla gölgelendirilmiş arazi';

  @override
  String get mapStylePreviewHeader => 'Önizleme';

  @override
  String get mapStylePreviewCity => 'Şehir';

  @override
  String get mapStylePreviewNature => 'Doğa';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Harita önizlemesi ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Harita önizlemesi bu sürümde kullanılamaz';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'Anlık önizleme yayın sürümlerinde görünür';

  @override
  String get aboutTitle => 'Hakkında';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline => 'Gizli ve sansüre dirençli konum paylaşımı.';

  @override
  String get aboutLicensesTitle => 'Açık kaynak lisansları';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'Bir harita sorunu bildir';

  @override
  String get aboutSupportOsm => 'OpenStreetMap\'i destekle';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nHarita verileri ODbL kapsamında lisanslanmıştır';

  @override
  String get aboutLinkOpenError => 'Bağlantı açılamadı';

  @override
  String get aboutFooterLicense => 'MIT License kapsamında lisanslanmıştır';

  @override
  String aboutFooterVersion(String version) {
    return 'Sürüm $version';
  }

  @override
  String get howItWorksTitle => 'How It Works';

  @override
  String get howItWorksIntro =>
      'Haven lets you share your live location with small groups of people, called circles. Your location is locked on your phone before it leaves, so the services that carry it can\'t read it, and neither can the people who make Haven.';

  @override
  String get howItWorksIdentityHeading => 'Your identity';

  @override
  String get howItWorksIdentityKeys =>
      'When you first open Haven, your phone creates your identity. It is a pair of matching keys, which are long codes. Your public key works like a username. It\'s safe to share, and people scan or paste it to invite you to a circle. Your secret key proves that you are you. It stays in a protected part of your phone, and Haven never sends it over the internet.';

  @override
  String get howItWorksIdentityBackup =>
      'There is no sign-up, email or phone number, so no company can reset your identity for you, and Haven keeps no other copy of your secret key. You can view it in Settings, under Identity, and keep a copy somewhere safe and private. Your circles can\'t be moved to another phone, so a new phone would need new invitations to rejoin them.';

  @override
  String get howItWorksIdentityProfile =>
      'Your display name and photo are public. When you save them, Haven publishes them as your profile on the Nostr network, with the photo on a separate photo server, and anyone can look them up. Haven starts you off with a random made-up name, so you don\'t have to use your real one.';

  @override
  String get howItWorksNostrHeading => 'The Nostr network';

  @override
  String get howItWorksNostrRelays =>
      'Haven runs on Nostr, an open network for passing messages over the internet. Nobody owns or controls it. Messages travel through relays, which are servers (computers that stay online) run by many independent people and organizations. Anyone can run a relay, and Haven runs none of its own.';

  @override
  String get howItWorksNostrChecks =>
      'Haven checks every message it receives, so a relay can\'t secretly change a message or fake one from someone else. A relay can still delay or delete messages, and each relay decides for itself what to accept and how long to keep it. Because the network has no central server, no single company runs it or can lock you out of your identity.';

  @override
  String get howItWorksNostrYourRelays =>
      'Your identity uses its own relays, which hold your profile and receive your invitations. You can see them on the Relays page in Settings and add others. Each circle sends its updates through its own set of relays, which you can see in that circle\'s details.';

  @override
  String get howItWorksEncryptionHeading => 'Encryption with MLS and Marmot';

  @override
  String get howItWorksEncryptionStandards =>
      'This locking is called encryption. It scrambles information so that only someone with the right key can unscramble (decrypt) it. Haven uses MLS (Messaging Layer Security), an open standard for encrypted group messaging published by the IETF, a group of experts that develops internet standards. Marmot is a protocol, a shared set of rules, that carries MLS messages over Nostr. Other apps use Marmot too.';

  @override
  String get howItWorksEncryptionCircleKeys =>
      'Each circle has its own secret keys, separate from your identity keys and held only by the phones of its members. Your phone encrypts your location with them before it leaves, and only phones in that circle can decrypt it. Because each circle has different keys, members of one circle can\'t see your other circles or who is in them.';

  @override
  String get howItWorksInvitationsHeading => 'Invitations and members';

  @override
  String get howItWorksInvitations =>
      'Haven publishes a public invitation key for you on your relays, so people can invite you even while your phone is offline. Circles are run by admins, who decide who is invited and who is removed. An invitation is sealed in layers of encryption. A relay can see who it is addressed to, but the invitation itself doesn\'t show who sent it or which circle it is for. Someone who is invited doesn\'t share their location with the circle until they accept.';

  @override
  String get howItWorksMembership =>
      'When someone is invited or removed, the circle switches to new keys. When someone leaves, their phone asks the others to make that switch. If nobody does, they stay in the circle until an admin removes them. A new member can read what the circle shares from the moment they are invited, but nothing from before. After a switch, someone who left or was removed can\'t read anything new, though they may still be able to tell when the circle is active. Anything that already reached their phone stays there. Members can see each other\'s locations, display names, photos and public keys.';

  @override
  String get howItWorksSharingHeading => 'Sharing your location';

  @override
  String get howItWorksSharingWhen =>
      'While Haven is open, it regularly shares your location with each of your circles. You can also turn on background sharing on the Location page in Settings, so sharing continues while you use other apps. How well that works depends on your phone and its settings.';

  @override
  String get howItWorksSharingUpdate =>
      'Each update is encrypted on your phone and sent to the circle\'s relays under a brand-new key that is used once and then thrown away, so the update by itself doesn\'t name who sent it. It also asks relays to delete it after a few minutes. Relays are expected to do so, but nothing forces them to, and the update stays encrypted either way. Your circle members\' phones pick it up, decrypt it, and show you on their map.';

  @override
  String get howItWorksMapHeading => 'The map';

  @override
  String get howItWorksMap =>
      'Map images come from an online map service. Haven asks it for the areas you view and the areas around your circle members, so the service can tell roughly which places those are. It doesn\'t learn your name, your keys, or who is in your circles.';

  @override
  String get howItWorksOnDeviceHeading => 'On your phone';

  @override
  String get howItWorksOnDevice =>
      'Haven keeps your circles in an encrypted database on your phone, and stores the key to that database in the phone\'s protected storage. Haven runs no servers of its own and contains no code that tracks how you use it or shows you ads. Its source code, the instructions that make up the app, is public, so anyone can check how it works.';

  @override
  String get howItWorksLimitsHeading => 'What Haven can\'t hide';

  @override
  String get howItWorksLimitsAddress =>
      'Relays, the map service and photo servers can see your phone\'s network address (its IP address), a number that identifies your internet connection. It can hint at your general area, and it can let relays link your updates, your circles and your public key to each other, especially if they share what they see. A VPN, a service that sends your internet traffic through its own computers, can hide your address by showing its own instead.';

  @override
  String get howItWorksLimitsPatterns =>
      'Relays can see when updates are sent, roughly how large they are, and which updates belong to the same circle. Their timing can also show which circles belong to the same phone, and roughly how many you are in. Someone watching internet traffic, such as an internet provider, may be able to tell that you use Haven and which phones are probably in the same circle. Haven isn\'t designed to hide your activity from someone who can watch many relays at once.';

  @override
  String get howItWorksLimitsPeople =>
      'The people in your circles see where you are, as precisely as your phone reports it, so share only with people you trust. Removing your name or photo later doesn\'t delete copies others already have, and a removed photo stays on the server that stored it. Haven also can\'t protect your information from someone who controls your phone.';

  @override
  String get relaySettingsBackendCaption =>
      'Haven\'ın kendine ait bir sunucusu yok. Şifreli güncellemeleriniz, aktarıcı adı verilen bağımsız sunucular üzerinden geçer; bu sunucular ne konumunuzu ne de mesajlarınızı okuyabilir.';

  @override
  String get commonClearAll => 'Tümünü Temizle';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString üye',
      one: '1 üye',
    );
    return '$_temp0';
  }

  @override
  String commonNumber(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get circlesTitle => 'Çevreler';

  @override
  String get circlesRefreshTooltip => 'Çevreleri yenile';

  @override
  String get circlesRequiresIdentity =>
      'Çevre oluşturmak için önce kimlik kurulumu gerekir';

  @override
  String get circlesCreateCta => 'Çevre Oluştur';

  @override
  String get circlesYourCircles => 'Çevreleriniz';

  @override
  String get circlesEmptyTitle => 'Henüz Çevre Yok';

  @override
  String get circlesEmptyMessage =>
      'Güvendiğiniz arkadaşlarınız ve ailenizle konum paylaşmaya başlamak için bir çevre oluşturun.';

  @override
  String get circlesSheetEmptyMessage =>
      'Güvendiğiniz kişilerle konum paylaşmaya başlamak için bir çevre oluşturun.';

  @override
  String get circlesLoadError => 'Çevreler yüklenemedi';

  @override
  String get circlesSelectToView => 'Üyeleri görmek için bir çevre seçin';

  @override
  String get circlesNoMembers => 'Bu çevrede üye yok';

  @override
  String get createCircleTitle => 'Üye Ekle';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Seçilen ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Çevre üyeleri ekleyin';

  @override
  String get createCircleEmptyMessage =>
      'Üye eklemek için kimliğe göre arayın ya da QR kodlarını tarayın.';

  @override
  String get createCircleNoValidMembers => 'Davet edilecek geçerli üye yok';

  @override
  String get createCircleNoIdInQr => 'QR kodunda geçerli bir kimlik bulunamadı';

  @override
  String get createCircleNoAccountFound =>
      'Bu tanımlayıcı için Haven hesabı bulunamadı';

  @override
  String get createCircleCouldNotVerify => 'Üye doğrulanamadı';

  @override
  String get createCircleSomethingWentWrong => 'Bir sorun oluştu';

  @override
  String get nameCircleTitle => 'Çevrenize Ad Verin';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString üye davet edilecek',
      one: '1 üye davet edilecek',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Çevre Adı';

  @override
  String get nameCircleNameHint => 'örn. Aile, Yakın Arkadaşlar';

  @override
  String get nameCircleNameEmptyError => 'Lütfen bir çevre adı girin';

  @override
  String get nameCircleNameTooLongError => 'Ad en fazla 50 karakter olmalıdır';

  @override
  String get nameCircleSharingInfo =>
      'Bu çevredeki herkes birbirinin konumunu, herkese açık adını ve fotoğrafını görebilir. Adınız ve fotoğrafınız Nostr ağında herkese açıktır; bu çevreye özel değildir. Bu çevre, içinde bulunduğunuz diğerlerinden ayrı kalır; bu nedenle üyeleri diğer çevrelerinizi ya da onlarda kimlerin olduğunu göremez.';

  @override
  String get nameCircleCreateCta => 'Çevre Oluştur';

  @override
  String get nameCircleStageCreatingGroup => 'Güvenli grup oluşturuluyor...';

  @override
  String get nameCircleStageComplete => 'Tamamlandı!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Oluşturma ilerlemesi: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return 'yüzde $percentString tamamlandı';
  }

  @override
  String nameCircleCreatedSentSoFarSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          '\"$name\" çevresi oluşturuldu. Şu ana kadar $totalString davetten $sentString tanesi gönderildi. Haven, uygulama açıkken kalan davetleri en fazla bir gün boyunca göndermeye devam eder.',
      one:
          '\"$name\" çevresi oluşturuldu. Şu ana kadar 1 davetten $sentString tanesi gönderildi. Haven, uygulama açıkken daveti en fazla bir gün boyunca göndermeye devam eder.',
    );
    return '$_temp0';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '\"$name\" çevresi oluşturuldu! $countString davet gönderildi.',
      one: '\"$name\" çevresi oluşturuldu! 1 davet gönderildi.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Kimlik hatası. Lütfen kimlik kurulumunuzu kontrol edin.';

  @override
  String get nameCircleCreateError =>
      'Çevre oluşturulamadı. Lütfen tekrar deneyin.';

  @override
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Aynı anda en fazla $limitString çevrede olabilirsiniz. Yenisine yer açmak için bir çevreden ayrılın.';
  }

  @override
  String get circleCreateRefusedNoLocationRelay =>
      'Haven bu çevreyi oluşturamaz: çevreler için kullandığı aktarıcıların her biri şu anda ya da daha önce kendi aktarıcı listelerinizde bulunduğu için hiçbiri bu çevreyi taşıyamaz.';

  @override
  String addMemberTitle(String circleName) {
    return '$circleName çevresine ekle';
  }

  @override
  String get addMemberInfo =>
      'Daveti kabul ettikleri andan itibaren herkesin konumunu görürler; katılmadan önce gönderilmiş hiçbir şeyi göremezler. Ayrıca bu çevrede halihazırda bulunan herkesin açık anahtarını da görürler.';

  @override
  String get addMemberAlreadyInCircle => 'Zaten bu çevrede';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Davetleri gönder',
      one: 'Davet gönder',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Davetler gönderiliyor...',
      one: 'Davet gönderiliyor...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Davetler $circleName çevresine gönderildi',
      one: 'Davet $circleName çevresine gönderildi',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentSoFar(int sent, int total, String circleName) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          '$circleName çevresi için şu ana kadar $totalString davetten $sentString tanesi gönderildi. Haven, uygulama açıkken kalan davetleri en fazla bir gün boyunca göndermeye devam eder.',
      one:
          '$circleName çevresi için şu ana kadar 1 davetten $sentString tanesi gönderildi. Haven, uygulama açıkken daveti en fazla bir gün boyunca göndermeye devam eder.',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'Haven, $circleName çevresi için daveti gönderemiyor. Bu kişiyi çıkarıp yeniden ekleyin.';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven seçtiğiniz herkesi davet edemiyor, çünkü davetlerden en az birinin nereye gönderileceğini bulamadı. Seçtiğiniz kişilerden, uygulamalarının davet alabildiğini kontrol etmelerini isteyin, ardından tekrar deneyin.';

  @override
  String get missedInvitationsShowWho => 'Kişileri göster';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Davetler gönderilemedi',
      one: 'Davet gönderilemedi',
    );
    return '$_temp0';
  }

  @override
  String get addMemberError => 'Üye eklenemedi. Lütfen tekrar deneyin.';

  @override
  String get qrScannerTitle => 'QR Kodu Tara';

  @override
  String get qrScannerToggleFlash => 'Flaşı aç/kapat';

  @override
  String get qrScannerSwitchCamera => 'Kamerayı değiştir';

  @override
  String get qrScannerInstruction => 'QR kodunu çerçeve içine yerleştirin';

  @override
  String get qrScannerScanning => 'Taranıyor...';

  @override
  String get circleMemberNoRecentLocation => 'Yakın zamanlı konum yok';

  @override
  String get circleMemberRemoveTooltip => 'Çevreden çıkar';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '$name çıkarılsın mı?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'Çevrenin geri kalanı bu değişikliği aldığında o kişi artık bu çevredeki yeni hiçbir şeyi okuyamaz; bu genellikle birkaç dakika sürer, o sırada çevrimdışı olanlar için daha uzun. O kişinin daha önce aldığı her şey kendi telefonunda kalır. Bunu geri almak için kişiyi yeniden davet etmeniz gerekir.';

  @override
  String get circleMemberRemoveConfirm => 'Çıkar';

  @override
  String circleMemberRemoveInProgress(String name) {
    return '$name çıkarılıyor…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name çevreden çıkarıldı';
  }

  @override
  String circleMemberRemoveError(String name) {
    return '$name çıkarılamadı. Hiçbir şey değişmedi — bağlantınızı kontrol edip tekrar deneyin.';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return '$name hâlâ çıkarılıyor: aktarıcılar bekleniyor. Bu tamamlanana kadar bu çevreyle hiçbir şey paylaşılmaz.';
  }

  @override
  String get circleMemberAdmin => 'Yönetici';

  @override
  String get circleMemberHintNoLocation => 'konum yok';

  @override
  String get circleMemberHintMember => 'üye';

  @override
  String get circleMemberHintTapToCenter =>
      'haritayı konumuna ortalamak için dokunun';

  @override
  String get pendingMemberRetryTooltip => 'Doğrulamayı yeniden dene';

  @override
  String get pendingMemberRemoveTooltip => 'Listeden kaldır';

  @override
  String get pendingMemberValidating => 'Doğrulanıyor';

  @override
  String get pendingMemberValid => 'Geçerli';

  @override
  String get pendingMemberWarning => 'Uyarı';

  @override
  String get pendingMemberCheckingAvailability => 'Uygunluk denetleniyor...';

  @override
  String get pendingMemberReadyToInvite => 'Davet edilmeye hazır';

  @override
  String get pendingMemberNeedsUpdate =>
      'Haven\'ı güncellemesi veya açması gerekiyor';

  @override
  String get memberKeyPackageStale =>
      'Haven şu anda bu kişiyi davet edemiyor. Haven\'ı açmasını isteyin, ardından tekrar deneyin.';

  @override
  String get memberSearchHint => 'Üye kimliğini girin...';

  @override
  String get memberSearchPasteTooltip => 'Panodan yapıştır';

  @override
  String get memberSearchAddTooltip => 'Üye ekle';

  @override
  String get memberSearchScanTooltip => 'QR Kodu Tara';

  @override
  String get memberSearchHelper =>
      'Kişilerinizden Haven QR kodunu ya da kimliğini isteyin';

  @override
  String get memberSearchNoValidId => 'Geçerli bir Haven kimliği bulunamadı';

  @override
  String get memberSearchAlreadyAdded => 'Üye zaten eklendi';

  @override
  String get memberPickerSectionRoster => 'Çevrelerinizdeki üyeler';

  @override
  String get memberPickerTierRoster => 'Çevrelerinizdeki üye';

  @override
  String get memberPickerNoMatches => 'Çevrelerinizde eşleşen kimse yok';

  @override
  String get memberPickerLoading => 'Çevrelerinizdeki kişi listesi okunuyor';

  @override
  String get memberPickerDirectoryUnavailable =>
      'Çevrelerinizdeki kişi listesi şu anda okunamadı';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Eşleşme sayısı: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'Bu sizin kendi kimliğiniz';

  @override
  String get memberPickerReadPublicKey => 'Açık anahtarı sesli oku';

  @override
  String get memberPickerSectionRecent =>
      'Son zamanlarda çevrelerinizdeki kişiler';

  @override
  String get memberPickerTierRecent => 'Son zamanlarda çevrelerinizdeydi';

  @override
  String get memberPickerNicknameNote =>
      'Sizin verdiğiniz takma ad, kişinin herkese açık adı değil';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'Çevre: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven, bu kişinin yayımlanmış adını bir aktarıcıya sordu. O aktarıcı, bu cihazın az önce bu anahtarı sorduğunu görür — ama bu istek imza taşımadığı için Haven kimliğinizle ilişkilendirilmez. Henüz hiçbir fotoğraf indirilmedi.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString daha';
  }

  @override
  String get invitationCardHeading => 'Çevre daveti';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Sizi bir çevreye $inviter davet etti';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Kriptografik tanımlayıcı $inviter tarafından davet edildi';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Davet eden: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'Sizin verdiğiniz takma ad, kişinin herkese açık adı değil';

  @override
  String get invitationCardJustNow => 'Az önce';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}g önce';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}sa önce';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}dk önce';
  }

  @override
  String get invitationCardDecline => 'Reddet';

  @override
  String get invitationCardAccept => 'Kabul Et';

  @override
  String get invitationAcceptedSnack => 'Davet kabul edildi';

  @override
  String get invitationDeclinedSnack => 'Davet reddedildi';

  @override
  String get invitationAcceptError =>
      'Davet kabul edilemedi. Lütfen tekrar deneyin.';

  @override
  String invitationNeedsNewInviteError(String name) {
    return 'Bu davet artık kullanılamaz. $name adlı kişiden sizi tekrar davet etmesini isteyin. Önce Haven\'ı güncellemesi gerekebilir.';
  }

  @override
  String get rejoinDialogTitle =>
      'Bu çevreye yeniden katılmak istiyor musunuz?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName sizi zaten bu telefonda bulunan “$circleName” çevresine davet etti. Bu durum, çevreden çıkarılıp yeniden davet edildiyseniz yaşanabilir. Yeniden katılırsanız bu telefondaki çevre kopyası yenisiyle değiştirilir. “Reddet” bu daveti kalıcı olarak sonlandırır; “İptal” ise daveti daha sonrası için saklar.';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'Zaten bu telefonda bulunan “$circleName” çevresine davet edildiniz. Bu durum, çevreden çıkarılıp yeniden davet edildiyseniz yaşanabilir. Yeniden katılırsanız bu telefondaki çevre kopyası yenisiyle değiştirilir. “Reddet” bu daveti kalıcı olarak sonlandırır; “İptal” ise daveti daha sonrası için saklar.';
  }

  @override
  String get rejoinDialogConfirm => 'Yeniden katıl';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Aynı anda en fazla $limitString çevrede olabilirsiniz. Bir çevreden ayrılın, sonra bu daveti kabul edebilirsiniz.';
  }

  @override
  String get invitationDeclineError =>
      'Davet reddedilemedi. Lütfen tekrar deneyin.';

  @override
  String get circleSelectorLabel => 'Çevre seçici';

  @override
  String get circleSelectorPlaceholder => 'Bir çevre seçin';

  @override
  String get circleSelectorNewCircle => 'Yeni Çevre';

  @override
  String get circleSelectorLoadError => 'Çevreler yüklenemedi';

  @override
  String get circleSelectorExpandedAnnouncement => 'Çevre listesi genişletildi';

  @override
  String get circleSelectorCollapsedAnnouncement => 'Çevre listesi daraltıldı';

  @override
  String get circleDetailsButtonTooltip => 'Çevre ayrıntıları';

  @override
  String get circleDetailsTitle => 'Çevre ayrıntıları';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · epoch $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · geçerlilik $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString dk',
      one: '$countString dk',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySecondsShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString sn',
      one: '$countString sn',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpiryMinutesLong(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'yaklaşık $countString dakika',
      one: 'yaklaşık $countString dakika',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySecondsLong(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString saniye',
      one: '$countString saniye',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven, bu çevreye gönderdiğiniz konum güncellemelerini aktarıcıların $expiry sonra silmesini ister.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Çevrenin aktarıcıları';

  @override
  String get circleDetailsNoRelays => '(kayıtlı yok)';

  @override
  String get circleDetailsRelaysNote =>
      'Bu çevrenin şifreli güncellemeleri bu aktarıcılar üzerinden iletilir. Aktarıcılar çevre oluşturulurken belirlendi ve henüz Haven\'da değiştirilemez; aktarıcı listenizdeki değişiklikler bunları etkilemez.';

  @override
  String get circleDetailsAddMember => 'Üye ekle';

  @override
  String get circleDetailsLeaveCircle => 'Çevreden Ayrıl';

  @override
  String get circleDetailsLeavingInProgress => 'Çevreden ayrılınıyor…';

  @override
  String get leaveCircleDialogTitle => 'Çevreden Ayrıl';

  @override
  String get leaveCircleDialogBody =>
      'Bu çevreden ayrılmak istiyor musunuz? Konumunuzu üyelerine göndermeyi ve onlarınkini görmeyi bırakacaksınız. Gönderdiğiniz son konum, bir güne kadar onların telefonlarında kalır. Bu işlem geri alınamaz: yeniden katılmak için yeni bir davet gerekir.';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'Bu çevre sona erdi, bu yüzden artık onunla hiçbir şey paylaşılmıyor. Çevreden ayrılmak onu bu telefondan kaldırır.';

  @override
  String get leaveCircleDialogAdminNote =>
      'Bu çevrenin yöneticisisiniz. Siz ayrılmadan önce Haven, çevrenin çalışmaya devam edebilmesi için başka bir üyeyi yönetici yapmaya çalışır.';

  @override
  String get leaveCircleConfirm => 'Ayrıl';

  @override
  String get leaveCircleIdentityUnavailable => 'Kimlik kullanılamıyor';

  @override
  String get leaveCircleSuccess => 'Çevreden başarıyla ayrıldınız';

  @override
  String get leaveCircleError => 'Çevreden ayrılınamadı';

  @override
  String get legacyCircleRecreateCta => 'Çevreyi Yeniden Oluştur';

  @override
  String get storageResetTitle => 'Haven güncellendi';

  @override
  String get storageResetKept =>
      'Kimliğiniz değişmedi ve daha önce yayımladığınız herkese açık profil olduğu gibi kalıyor.';

  @override
  String get storageResetLost =>
      'Haven\'ın yeni şifreleme motoruna geçmek için bu güncellemeden önce oluşturulan çevreler kaldırıldı. Onları yeniden oluşturun ve üyelerini tekrar davet edin. Bu güncellemeden önce kişilere verdiğiniz takma adlar ve o zamana kadar kaydedilmesi tamamlanmamış profil değişiklikleri de kaldırıldı.';

  @override
  String get storageResetRelays =>
      'Bu güncelleme aktarıcı ayarlarınızı Haven\'ın varsayılanlarına sıfırladı. Siz devam edene ya da Aktarıcı ayarları\'ndan dönene kadar bu ayarlar yayımlanmaz; bu yüzden önce kendi aktarıcılarınızı ekleyebilirsiniz.';

  @override
  String get storageResetContinue => 'Devam Et';

  @override
  String get storageResetOpenRelaySettings => 'Aktarıcı ayarları';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven yanıtınızı kaydedemedi. Yanıtınız kaydedilene kadar Haven aktarıcı ayarlarınızı ve davet anahtarınızı yayımlamaz; bu yüzden henüz kimse sizi davet edemez. Tekrar deneyin; yoksa Haven bir dahaki açılışta yeniden soracak.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'Çevreler paneli daraltıldı';

  @override
  String get circlesPanelExpandedAnnouncement => 'Çevreler paneli genişletildi';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'Çevreler paneli biraz açık';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'Çevreler paneli yarı açık';

  @override
  String get circleMemberAnnouncementSelf => 'siz';

  @override
  String get circleMemberAnnouncementFallback => 'üye';

  @override
  String get invitationsRefreshTooltip => 'Davetleri yenile';

  @override
  String get invitationsLoadError => 'Davetler yüklenemedi';

  @override
  String get invitationsEmptyTitle => 'Davet Yok';

  @override
  String get invitationsEmptyMessage =>
      'Biri sizi bir çevreye davet ettiğinde burada görünecek.';

  @override
  String get refreshRingSemanticNoInbox =>
      'Gelen kutusu yapılandırılmadı, aktarıcı ayarlarını açar';

  @override
  String refreshRingSemanticChecking(int checked, int total) {
    final intl.NumberFormat checkedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String checkedString = checkedNumberFormat.format(checked);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString aktarıcıdan $checkedString tanesi denetlendi',
      one: '1 aktarıcıdan $checkedString tanesi denetlendi',
    );
    return '$_temp0';
  }

  @override
  String refreshRingSemanticAllOk(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString aktarıcının tümü yanıt verdi',
      one: 'Aktarıcı yanıt verdi',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'Hiçbir aktarıcı yanıt vermedi';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString aktarıcıdan $okString tanesi yanıt verdi';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Aktarıcılar denetleniyor';

  @override
  String get refreshRingAnnouncementAllOk => 'Tüm aktarıcılar yanıt verdi';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString aktarıcıdan $okString tanesi yanıt verdi';
  }

  @override
  String get refreshRingAnnouncementAllError => 'Hiçbir aktarıcıya ulaşılamadı';

  @override
  String get refreshRingAnnouncementNoInbox => 'Gelen kutusu yapılandırılmadı';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString aktarıcının tümünde verileriniz var',
      one: 'Aktarıcıda verileriniz var',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound =>
      'Hiçbir aktarıcıda verileriniz yok';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString aktarıcıdan $okString tanesinde verileriniz var';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'Tüm aktarıcılarda verileriniz var';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString aktarıcıdan $okString tanesinde verileriniz var';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'Hiçbir aktarıcıda verileriniz yok';

  @override
  String get identityTitle => 'Kimlik';

  @override
  String get identityLoadError =>
      'Kimliğiniz yüklenirken bir sorun oluştu. Lütfen tekrar deneyin.';

  @override
  String get identityMissingTitle => 'Kimlik Yok';

  @override
  String get identityMissingMessage =>
      'Kimliğiniz kaybolmuş. Haven\'ı kullanmaya devam etmek için yeni bir tane oluşturun.';

  @override
  String get identitySetUpCta => 'Kimlik Oluştur';

  @override
  String get identityPublicKeyQrTitle => 'Açık Anahtar QR\'ı';

  @override
  String get identityPublicKeyQrSubtitle =>
      'Başkaları sizi çevrelere böyle davet eder';

  @override
  String get identityAdvancedTitle => 'Gelişmiş';

  @override
  String get identityAdvancedSubtitle => 'Açık anahtar, gizli anahtar, silme';

  @override
  String get profileIsPublicNoticeTitle => 'Profil herkese açık';

  @override
  String get profileIsPublicNoticeBody =>
      'Görünen adınız ve fotoğrafınız yalnızca çevrelerinizin üyelerine değil, Nostr ağındaki herkese görünür. Yalnızca herkese açık olmasında sakınca görmediğiniz şeyleri paylaşın.';

  @override
  String get identityRefreshProfileTooltip => 'Herkese açık profili yenile';

  @override
  String get identityAdvancedExportError =>
      'Gizli anahtar dışa aktarılamadı. Lütfen tekrar deneyin.';

  @override
  String get identityAdvancedDeleteTitle => 'Kimlik Silinsin mi?';

  @override
  String get identityAdvancedDeleteBody =>
      'Bu işlem, kimliğinizi ve tüm çevre verilerinizi bu telefondan siler. Bu kimlikle daha önce yayımlanmış her şey olduğu yerde kalır: adınız ve anahtarlarınız onlara sahip aktarıcılarda, fotoğrafınız da onu saklayan görsel barındırma hizmetinde. Kimliğinizi geri getirmek istiyorsanız gizli anahtarınızı yedeklediğinizden emin olun.';

  @override
  String get identityAdvancedDeleteConfirm => 'Sil';

  @override
  String get identityAdvancedDeletedSnack => 'Kimlik silindi';

  @override
  String get identityAdvancedDeleteError =>
      'Kimlik silinemedi. Lütfen tekrar deneyin.';

  @override
  String get identityAdvancedDeletingProgress => 'Kimliğiniz siliniyor…';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label panoya kopyalandı';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Gizli anahtar kopyalandı. Uyarı: diğer uygulamalar panonuzu okuyabilir. Güvenli bir yere yapıştırın ve panonuzu temizleyin.';

  @override
  String get identityAdvancedMissingBody => 'Kurulu bir kimlik yok.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Açık Anahtar';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'Açık Anahtar (hex)';

  @override
  String get identityAdvancedCopyValue => 'Açık anahtar';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'Açık anahtarı kopyala';

  @override
  String get identityAdvancedCopyHexTooltip => 'hex değerini kopyala';

  @override
  String get identityAdvancedSecretKeyTitle => 'Gizli Anahtar';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Gizli anahtarınız kimliğinize tam erişim sağlar. Asla kimseyle paylaşmayın.';

  @override
  String get identityAdvancedRevealSecretKey => 'Gizli Anahtarı Göster';

  @override
  String get identityAdvancedHideSecretKey => 'Gizli Anahtarı Gizle';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'Gizli anahtarı kopyala';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Kimliği Sil';

  @override
  String get qrCodeLoadError =>
      'Açık anahtarınız yüklenirken bir sorun oluştu. Lütfen tekrar deneyin.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Açık anahtarınız';

  @override
  String get qrCodeWhatIsThisTitle => 'Bu nedir?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven, arkasında hiçbir şirket hesabı ya da kaydı olmayan açık bir ağ olan Nostr üzerinde çalışır. Kimliğiniz yalnızca bir anahtar çiftidir: yalnızca sizde olan bir gizli anahtar ve ondan oluşturulan bu açık anahtar.';

  @override
  String get qrCodeExplainerUsername =>
      'Açık anahtarınız, paylaşılması güvenli bir kullanıcı adı gibi çalışır. İnsanlar sizi bir çevreye davet etmek için bu kodu tarar ya da açık anahtarınızı yapıştırır. Bunu paylaşmak nerede olduğunuzu açığa çıkaramaz. Görünen adınız ve fotoğrafınız zaten herkese açık olduğundan bu, onlara bir şey eklemez.';

  @override
  String get displayNameCardTitle => 'Görünen Ad';

  @override
  String get displayNameCardLoadError =>
      'Görünen adınız yüklenemedi. Daha sonra tekrar deneyin.';

  @override
  String get displayNameCardHint => 'Görünen adınızı girin';

  @override
  String get displayNameCardSavedLabel => 'Görünen ad kaydedildi';

  @override
  String get displayNameCardSaveLabel => 'Görünen adı kaydet';

  @override
  String get displayNameCardSavingLabel => 'Görünen ad kaydediliyor';

  @override
  String get displayNameCardRetryLabel =>
      'Kaydetme başarısız oldu. Yeniden deneyin';

  @override
  String get displayNameCardSavedAnnouncement => 'Görünen ad kaydedildi';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'Kaydetme başarısız oldu, tekrar deneyin';

  @override
  String get npubQrCopiedSnack => 'Açık anahtar panoya kopyalandı';

  @override
  String get npubQrCopyButton => 'Açık anahtarı kopyala';

  @override
  String get circleMemberPublicKeyCopied => 'Açık anahtar panoya kopyalandı';

  @override
  String get circleMemberCopyPublicKeyHint => 'Açık anahtarı kopyala';

  @override
  String get circleMemberSetNicknameMenuItem => 'Takma Ad Belirle';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'Açık Anahtarı Kopyala';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'Profiller yenilenemedi. Lütfen tekrar deneyin.';

  @override
  String get memberDetailSheetTitle => 'Üye Ayrıntıları';

  @override
  String get memberNicknameSheetHint => 'Bir takma ad girin';

  @override
  String get memberNicknameSheetLabel => 'Takma Ad';

  @override
  String get memberNicknameSheetSave => 'Takma Adı Kaydet';

  @override
  String get memberNicknameSheetClear => 'Takma Adı Temizle';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Takma ad kaydedildi';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Takma ad temizlendi';

  @override
  String get npubQrScanLabel => 'Beni eklemek için tarayın';

  @override
  String get npubQrSemanticsLabel => 'Açık kimliğiniz için QR kodu';

  @override
  String get photoHeaderRemoveTitle => 'Profil fotoğrafı kaldırılsın mı?';

  @override
  String get photoHeaderRemoveBody =>
      'Bu işlem, fotoğrafınızı herkese açık profilinizden kaldırır. Görsel dosyası onu barındıran sunucuda kalır ve başkalarının daha önce indirdiği kopyalar onlarda kalmaya devam eder.';

  @override
  String get photoHeaderEditPhoto => 'Fotoğrafı Düzenle';

  @override
  String get photoHeaderRemove => 'Kaldır';

  @override
  String get photoHeaderViewPhotoSemantics => 'Profil fotoğrafını görüntüle';

  @override
  String get photoHeaderAddPhotoSemantics => 'Profil fotoğrafı ekle';

  @override
  String get photoHeaderChangePhotoSemantics => 'Profil fotoğrafını değiştir';

  @override
  String get avatarPickerPhotoUpdatedAnnouncement => 'Fotoğraf güncellendi.';

  @override
  String get avatarPickerPhotoRemoved => 'Fotoğraf kaldırıldı.';

  @override
  String get avatarPickerRemoveError =>
      'Fotoğrafınız kaldırılamadı. Lütfen tekrar deneyin.';

  @override
  String get avatarPickerUpdateError =>
      'Fotoğrafınız güncellenemedi. Lütfen tekrar deneyin.';

  @override
  String get avatarPickerCropTitle => 'Fotoğrafı kırp';

  @override
  String get avatarPickerCropDone => 'Tamam';

  @override
  String get avatarPickerCropCancel => 'İptal';

  @override
  String get avatarFullscreenClose => 'Kapat';

  @override
  String get avatarFullscreenSemantics => 'Profil fotoğrafı, tam ekran';

  @override
  String get avatarFullscreenLoadError => 'Fotoğraf yüklenemedi';

  @override
  String get mapInitializing => 'Başlatılıyor...';

  @override
  String get mapInitFailedTitle => 'Başlatma Başarısız';

  @override
  String get mapInitFailedMessage => 'Konum hizmetleri başlatılamadı.';

  @override
  String get mapInitFailedRetry =>
      'Başlatma başarısız oldu. Lütfen tekrar deneyin.';

  @override
  String get mapLocationOffMessage =>
      'Kendinizi ve çevrelerinizi haritada görmek için konumu açın.';

  @override
  String get mapGettingLocation => 'Konum alınıyor...';

  @override
  String get mapLoadingMap => 'Harita yükleniyor...';

  @override
  String get mapLocationOffTitle => 'Konum kapalı';

  @override
  String get mapLocationErrorTitle => 'Konum Hatası';

  @override
  String get mapLocationUnavailable => 'Konum geçici olarak kullanılamıyor';

  @override
  String get mapLocationNoPermissionTitle => 'Haven konumunuzu kullanamıyor';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'Bu cihazda konum kapatıldı, bu yüzden Haven konumunuzu çevrelerinizle paylaşmayı durdurdu. Paylaşımı yeniden başlatmak için konumu açın.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven\'ın konumunuzu kullanma izni artık yok, bu yüzden paylaşım durdu. Yeniden başlatmak için konum erişimine izin verin.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'Haven için konum erişimi sistem ayarlarında kapalı, bu yüzden paylaşım durdu. Yeniden başlatmak için izni oradan verin.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven konumunuzu paylaşmayı durdurdu. Bu cihazda konumu açın ve Haven\'a konum izni verin.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven konumunuzu almayı durdurdu, bu yüzden paylaşım da durdu. Konumun açık olduğundan ve Haven\'ın konum izni olduğundan emin olun.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Konum erişimi geri geldi. Haven konumunuzu yeniden paylaşıyor.';

  @override
  String get clockSkewTitle => 'Bu telefonun saati yanlış';

  @override
  String get clockSkewBodyRejected =>
      'Çevreleriniz konumunuzu alamıyor, çünkü aktarıcılar bu telefonun konuma eklediği zaman damgasını kabul etmiyor. Bunu düzeltmek için sistem ayarlarından tarih ve saatin otomatik ayarlanmasını açın.';

  @override
  String get clockSkewBodyBehind =>
      'Bu telefonun saati çevrelerinizdekilere göre geri kalıyor. Konumlarınız gönderiliyor ama erken geçerliliğini yitiriyor; çevreleriniz bunların bir kısmını ya da tamamını kaçırabilir. Bunu düzeltmek için sistem ayarlarından tarih ve saatin otomatik ayarlanmasını açın.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'Saat sorunu giderildi. Haven konumunuzu yeniden paylaşıyor.';

  @override
  String get clockSkewTitleDisagreement =>
      'Çevrelerinizden birindeki saatlerden biri yanlış';

  @override
  String get clockSkewBodyDisagreement =>
      'Bu telefonun saati ile başka bir üyenin saati arasında iki dakika veya daha fazla fark var. Yanlış olan bu telefonunki ise, gönderdiği konumlar kimse görmeden geçerliliğini yitirebilir. Bu telefonun saatinin yanlış olmadığından emin olmak için sistem ayarlarından tarih ve saatin otomatik ayarlanmasını açın.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'Saat uyarısı kalktı.';

  @override
  String get sharingHealthTitleStopped => 'Konum paylaşımı durdu';

  @override
  String get sharingHealthTitleNotSending => 'Konumunuz paylaşılmıyor';

  @override
  String get sharingHealthTitleNotReceiving =>
      'Diğer üyelerin konumları gelmiyor';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Yaklaşık $countString dakikadır güncelleme yok',
      one: 'Yaklaşık 1 dakikadır güncelleme yok',
    );
    return '$_temp0';
  }

  @override
  String sharingHealthNoUpdatesHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Yaklaşık $countString saattir güncelleme yok',
      one: 'Yaklaşık 1 saattir güncelleme yok',
    );
    return '$_temp0';
  }

  @override
  String sharingHealthNoUpdatesDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Yaklaşık $countString gündür güncelleme yok',
      one: 'Yaklaşık 1 gündür güncelleme yok',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Onar';

  @override
  String get sharingHealthRepairSent =>
      'Onarım gönderildi. Diğer üyelerin telefonları onu aldığında konumları yeniden gelmeye başlayacak.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Şu anda onarılacak bir şey yok. Haven denemeye devam edecek.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'Konum paylaşımı hâlâ çalışmıyor.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'Konum paylaşımı yeniden çalışıyor.';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven şu anda bu çevreyi açamıyor';

  @override
  String get sharingHealthBodyQuarantined =>
      'Bu çevre bu telefonda yüklenirken bir sorun oluştu. Çevre hâlâ burada.';

  @override
  String get sharingHealthTitleDisbanded => 'Bu çevre sona erdi';

  @override
  String get sharingHealthBodyDisbanded =>
      'Bir yönetici bu çevreyi sona erdirdi, bu yüzden artık onunla hiçbir şey paylaşılmıyor. Bu telefondan kaldırmak için çevreden ayrılın.';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'Bu çevreyi yeniden yüklemeyi dener';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven bu çevreyi hâlâ açamıyor.';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'Bu çevre bu telefonda çalışmayı durdurdu';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven, bu telefonda bu çevrede artık güncelleme gönderemiyor ya da alamıyor. Çevrenin yöneticilerinden birinden sizi çıkarıp yeniden eklemesini isteyin. Bunu yapabilecek kimse yoksa aynı kişilerle yeni bir çevre oluşturun.';

  @override
  String get sharingHealthTitleStalled =>
      'Haven bu çevrenin güncellemelerini okuyamıyor';

  @override
  String get sharingHealthBodyStalled =>
      'Bu telefon, çevrede yapılan bir değişikliği kaçırmış gibi görünüyor ve bu değişikliği aktarıcılarda bulamadı. Çevrenin yöneticilerinden birinden sizi çıkarıp yeniden eklemesini isteyin. Bunu yapabilecek kimse yoksa aynı kişilerle yeni bir çevre oluşturun.';

  @override
  String get sharingHealthTitlePaused => 'Haven bu çevreyi duraklattı';

  @override
  String get sharingHealthBodyCollision =>
      'Haven, bu telefonda bu çevreyle ilgili bir sorun buldu ve konumunuzu gizli tutmak için bu çevreyle paylaşımı durdurdu. Bunu düzeltmenin tek yolu çevreden ayrılmaktır. Yeniden katılmak için yeni bir davet gerekir.';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven bu telefonda bu çevreyi denetleyemedi, bu yüzden konumunuzu gizli tutmak için bu çevreyle paylaşımı duraklattı. Haven bunu kendiliğinden yeniden denetler.';

  @override
  String get sharingHealthTitleLeaving => 'Bu çevreden ayrılıyorsunuz';

  @override
  String get sharingHealthBodyLeaving =>
      'Haven bu çevreden ayrılmayı tamamlarken çevreyle hiçbir şey paylaşılmaz. Bu, yaklaşık bir gün sürebilir. Tamamlandığında çevre bu telefondan kaybolur.';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'İstediğiniz bir çıkarma işlemi yapılmadığı için Haven, konumunuzu çıkarmaya çalıştığınız herkesten uzak tutmak amacıyla bu çevreyle paylaşmayı duraklattı.';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'İstediğiniz bir çıkarma işlemi yapılmadığı için Haven, konumunuzu çıkarmaya çalıştığınız herkesten uzak tutmak amacıyla bu çevreyle paylaşmayı duraklattı. Çevrede hâlâ kimlerin bulunduğunu görmek için üye listesini açın.';

  @override
  String get sharingHealthBodyDepartureDue =>
      'Biri bu çevreden ayrıldı, ancak ayrılma işlemi henüz tamamlanmadı. Tamamlanana kadar Haven konumunuzu bu çevreyle paylaşmaz.';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'Bu çevre için arka planda paylaşım duraklatıldı';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Bu çevrenin aktarıcıları, Haven arka plandayken değişti. Haven geçişi açıkken tamamlar; o zamana kadar bu çevreyle arka planda paylaşım yapılmaz.';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'Bu çevredeki bir değişiklik, bir aktarıcının onaylamasını bekliyor. O zamana kadar Haven konumunuzu bu çevreye göndermiyor ve bu çevreden gelen yeni konumları göstermiyor. Haven, uygulama açıkken denemeye devam eder.';

  @override
  String get sharingHealthBodyAcknowledged =>
      'Bir aktarıcı bu çevredeki bir değişikliği kabul etti ve Haven değişikliği tamamlıyor. Tamamlanana kadar bu çevrenin güncellemeleri bekler.';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'Bu çevredeki bir değişiklik kaydedilemedi, bu yüzden gönderilmedi. Haven bunu en geç bir dahaki açılışında çözer; o zamana kadar bu çevrenin güncellemeleri bekler.';

  @override
  String get sharingHealthBodyStoredInput =>
      'Bu telefonun, bu çevre için henüz işleyemediği güncellemeler var. Bunlar işlenene kadar Haven konumunuzu bu çevreyle paylaşmaz.';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven son bağlantısını hâlâ kapatıyor, bu yüzden konum paylaşımı duraklatıldı. Bu tamamlanınca paylaşım kaldığı yerden devam eder. Telefonunuzu yeniden başlatmak bu durumu her zaman giderir.';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'Aktarıcılara yeniden bağlanır, konumunuzu göndermeyi tekrar dener ve bu çevreye yeni şifreleme anahtarları verebilir';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'Bu çevrede konum paylaşımı dikkatinizi gerektiriyor. Nedenini görmek için Çevre ayrıntıları bölümünü açın.';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return '$circleName çevresinde yapılan son değişikliklerle ilgili bir konu dikkatinizi gerektiriyor. Bunu okumak için o çevrenin ayrıntılarını açın.';
  }

  @override
  String get circleDetailsAttentionTooltip =>
      'Çevre ayrıntıları, dikkat gerektiriyor';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, dikkat gerektiriyor';
  }

  @override
  String get changeNoticeHeading => 'Bu çevredeki değişiklikler';

  @override
  String get changeNoteRemovalUndone =>
      'Bu çevredeki bir değişiklik gerçekleşmedi. Bu değişiklik çevreden birini çıkarıyorduysa, çıkaracağı herkes hâlâ çevrede ve çevreyle paylaşılanları görebilir.';

  @override
  String get changeNoteChangeUndone =>
      'Bu çevredeki bir değişiklik gerçekleşmedi, bu yüzden hiçbir şey değişmedi. Değişiklik sizinse ve hâlâ istiyorsanız yeniden yapın.';

  @override
  String get changeNoteMayBeOutOfStep =>
      'Bu çevredeki bir değişiklik, bu telefonun haberi olmadan diğerlerine ulaşmış olabilir; bu yüzden bu telefon onlarla aynı noktada olmayabilir.';

  @override
  String get changeNoteReinviteOwed =>
      'Davet ettiğiniz biri bu çevrede listeleniyor ama katılamıyor, çünkü Haven bu kişinin davetini gönderemiyor. Bu kişiyi çıkarıp yeniden ekleyin.';

  @override
  String get changeNoteChangeUnrecorded =>
      'Bu çevredeki bir değişiklik kaydedilemedi, bu yüzden gönderilmedi.';

  @override
  String get changeNoteQueuedChangeDropped =>
      'Bu çevrede yapılmayı bekleyen bir değişiklik, artık istendiği gibi yapılamadığı için iptal edildi. Başka bir yolla zaten yapılmış olabilir.';

  @override
  String get changeNoteQueuedChangesHeld =>
      'Bu çevredeki bazı değişiklikler hâlâ yapılmayı bekliyor.';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'Bu çevrede istediğiniz bir çıkarma işlemi yapılmadı. Çıkarmaya çalıştığınız herkes hâlâ çevrede olabilir.';

  @override
  String get changeNoteChangeWithdrawn =>
      'Başka bir üyenin bu çevredeki değişikliği sizinkilerden birinin yerini aldı, bu yüzden sizinki yapılmadı. Hâlâ istiyorsanız yeniden yapın.';

  @override
  String get changeNoteWelcomeOwed =>
      'Bu çevre için bir davet henüz gönderilemedi. Haven, davet ettiğiniz andan itibaren en fazla bir gün boyunca, uygulama açıkken bu daveti göndermeye devam eder. Kişi o zamana kadar katılmadıysa onu çıkarıp yeniden ekleyin.';

  @override
  String get changeNoteUnreadLocation =>
      'Bu çevreye son gönderilen bazı güncellemeler bu telefonda açılamadı.';

  @override
  String get changeNoticeStillInCircleLabel => 'Hâlâ çevrede:';

  @override
  String get changeNoticeRemoveAgain => 'Yeniden çıkar';

  @override
  String get changeNoticeReviewMembers => 'Üyeleri incele';

  @override
  String get changeNoticeKeepMembers => 'Çevrede tut';

  @override
  String get changeNoticeKeepConfirmTitle => 'Çevrede tutulsun mu?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'Haven, bu çıkarma işlemi yüzünden bu çevreyle paylaşımı artık duraklatmayacak. Çıkarmaya çalıştığınız ve hâlâ çevrede olan herkes çevrede kalır ve Haven konumunuzu bu çevreyle her paylaştığında onu görebilir.';

  @override
  String get changeNoticeKeepConfirmAction => 'Çevrede tut';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Son görülme $countString dakika önce',
      one: 'Son görülme 1 dakika önce',
    );
    return '$_temp0';
  }

  @override
  String get mapThisLocation => 'bu konum';

  @override
  String get mapMemberFallbackName => 'üye';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '$label Apple Maps\'te açılsın mı?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Apple Maps\'e yalnızca harita koordinatı gönderilir; asla bir ad ya da kimlik gönderilmez.';

  @override
  String get mapOpenInAppleMapsConfirm => 'Apple Maps\'te aç';

  @override
  String get mapOpenMapsError => 'Maps açılamadı';

  @override
  String get mapControlsZoomIn => 'Yakınlaştır';

  @override
  String get mapControlsZoomOut => 'Uzaklaştır';

  @override
  String get mapControlsRecenter => 'Yeniden ortala';

  @override
  String get mapControlsRecenterFab => 'Konumuma yeniden ortala';

  @override
  String get mapAttributionCreditsButton => 'Harita katkıları ve lisansı';

  @override
  String get userLocationMarkerSemantics => 'Konum işaretiniz';

  @override
  String memberMarkerMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m';
  }

  @override
  String memberMarkerMinutesAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString dakika önce',
      one: '1 dakika önce',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return '$name üye işareti';
  }

  @override
  String get memberMarkerGenericSemantics => 'Üye işareti';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, son görülme $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name ekran dışında, $direction yönünde; görmek için dokunun';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'Bir üye ekran dışında, $direction yönünde; görmek için dokunun';
  }

  @override
  String get compassNorth => 'kuzey';

  @override
  String get compassNorthEast => 'kuzeydoğu';

  @override
  String get compassEast => 'doğu';

  @override
  String get compassSouthEast => 'güneydoğu';

  @override
  String get compassSouth => 'güney';

  @override
  String get compassSouthWest => 'güneybatı';

  @override
  String get compassWest => 'batı';

  @override
  String get compassNorthWest => 'kuzeybatı';

  @override
  String get commonAdd => 'Ekle';

  @override
  String get addRelaySheetTitleInbox => 'Gelen Kutusu aktarıcısı ekle';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage aktarıcısı ekle';

  @override
  String get addRelaySheetTitleProfile => 'Profil aktarıcısı ekle';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Panodan yapıştır';

  @override
  String get addRelaySheetErrorEmpty => 'Bir aktarıcı adresi girin.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Bu aktarıcıya giden trafiğin şifrelenmesi için wss:// kullanın.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'Aktarıcı adresi kimlik bilgileri içermemelidir.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'wss://relay.example.com gibi bir aktarıcı adresi girin.';

  @override
  String get avatarSemanticsLabel => 'Kullanıcı avatarı';

  @override
  String avatarSemanticsFor(String initials) {
    return '$initials için';
  }

  @override
  String get avatarSemanticsOnline => 'çevrimiçi';

  @override
  String get avatarSemanticsOffline => 'çevrimdışı';
}
