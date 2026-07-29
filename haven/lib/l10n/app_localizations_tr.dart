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
      'Konumunuzu yalnızca istediğiniz kişilerle, gizlice paylaşın.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'yalnızca';

  @override
  String get onboardingWelcomeCta => 'Başla';

  @override
  String get onboardingValuePropsTitle => 'Haven\'ı farklı kılan ne?';

  @override
  String get onboardingValueProp1Title =>
      'Sizi yalnızca çevreleriniz görebilir';

  @override
  String get onboardingValueProp1Body =>
      'Konumunuz cihazınızdan çıkmadan önce şifrelenir; böylece yalnızca seçtiğiniz çevreler onu okuyabilir, Haven ya da başka biri asla okuyamaz. Haven açık kaynak olduğundan bunu herkes doğrulayabilir.';

  @override
  String get onboardingValueProp2Title => 'Kimse kapatamaz';

  @override
  String get onboardingValueProp2Body =>
      'Haven\'ın merkezi bir sunucusu yoktur. Şifreli mesajlarınız, kendiniz seçebileceğiniz merkeziyetsiz bir aktarıcı ağı üzerinden iletilir; böylece tek bir kuruluş onu kapatamaz.';

  @override
  String get onboardingValueProp3Title => 'Hesaba gerek yok';

  @override
  String get onboardingValueProp3Body =>
      'E-posta yok, telefon numarası yok, kayıt yok. Haven, gizli anahtarı telefonunuzdan hiç çıkmayan bir kimlik oluşturur; bu yüzden kimsenin teslim edebileceği bir hesap da yoktur.';

  @override
  String get onboardingValueProp1Summary =>
      'Cihazınızda şifrelenir; yalnızca seçtiğiniz çevreler görebilir.';

  @override
  String get onboardingValueProp2Summary =>
      'Merkezi sunucu yok; seçtiğiniz aktarıcı ağı üzerinden çalışır.';

  @override
  String get onboardingValueProp3Summary =>
      'E-posta, telefon veya kayıt yok. Gizli anahtarınız telefonunuzdan hiç çıkmaz.';

  @override
  String get onboardingCreateIdentityTitle => 'Kimliğinizi oluşturun';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven yalnızca bu telefonda yaşayan özel bir kimlik oluşturacak. Çevreleriniz sizi bu sayede tanır.';

  @override
  String get onboardingCreateIdentityWarning =>
      'Bu telefonu kaybeder ya da uygulamayı silerseniz kimliğiniz tamamen kaybolur. Haven\'ın bunu sizin için kurtarmasının hiçbir yolu yoktur.';

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
  String get settingsIdentitySubtitle =>
      'Profil, anahtarlar ve fotoğraf paylaşımı';

  @override
  String get settingsRelaysTitle => 'Aktarıcılar';

  @override
  String get settingsRelaysSubtitle => 'Davetlerin size ulaştığı yer';

  @override
  String get settingsLocationTitle => 'Konum';

  @override
  String get settingsLocationSubtitle => 'Arka planda paylaşım ve izinler';

  @override
  String get settingsMapStyleTitle => 'Harita stili';

  @override
  String get settingsAppearanceSubtitle => 'Tema ve dil';

  @override
  String get settingsAboutTitle => 'Hakkında';

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
      'kind 10002, davet edilenlerin şifreleme anahtarlarınızı bulduğu yer';

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
  String get locationSettingsErrorSnack => 'Bir sorun oluştu';

  @override
  String get locationSettingsIntro =>
      'Arka planda paylaşım açıkken, Haven kapalı olsa bile çevreleriniz anlık konumunuzu görmeye devam eder.';

  @override
  String get locationSettingsToggleTitle => 'Arka planda paylaş';

  @override
  String get locationSettingsToggleSubtitle =>
      'Uygulama kapalıyken de paylaşmaya devam et';

  @override
  String get locationSettingsIosLimitedNote =>
      'Paylaşım, mevcut izninizle arka planda çalışmaya devam eder. iOS uygulamayı kapatsa bile güncellemelerin sürebilmesi için Ayarlar\'da Haven için Konum\'u \'Her Zaman\' olarak ayarlayın.';

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
      'Arka planda paylaşım açıkken Haven kesintisiz bir konum oturumu sürdürür ve iOS durum çubuğunda mavi bir gösterge görüntüler. Ayrıca \"Her Zaman\" iznini verirseniz Haven, iOS uygulamayı kapattıktan sonra da çevrelerinizdeki gelişmeleri yakalayabilir.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License kapsamında lisanslanmıştır';

  @override
  String aboutFooterVersion(String version) {
    return 'Sürüm $version';
  }

  @override
  String get privacyTitle => 'Gizlilik';

  @override
  String get privacySubtitle =>
      'Haven nasıl çalışır ve başkaları neyi görebilir';

  @override
  String get privacyHubSummary =>
      'Haven konumunuzu yalnızca seçtiğiniz küçük gruplarla paylaşır ve telefonunuzdan çıkmadan önce şifreler. Arkasında bir şirket hesabı ya da Haven sunucusu yoktur. Aşağıdaki sayfalar bunun nasıl işlediğini sade bir dille anlatır ve neyi korumadığı konusunda da dürüsttür.';

  @override
  String get privacyGroupBasicsHeading => 'Temel bilgiler';

  @override
  String get privacyMeansForYouLabel => 'Bunun sizin için anlamı';

  @override
  String get privacyMoreDetailLabel => 'Daha ayrıntılı bilgi';

  @override
  String get privacyMoreDetailExpandHint => 'Teknik ayrıntıları göster';

  @override
  String get privacyMoreDetailCollapseHint => 'Teknik ayrıntıları gizle';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'Teknik ayrıntılar gösterildi';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Teknik ayrıntılar gizlendi';

  @override
  String get privacyWhatHavenIsTitle => 'Haven nedir ve neden hesap yok';

  @override
  String get privacyWhatHavenIsSubtitle => 'Kayıt yok, şirket sunucusu yok';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven konumunuzu, çevre adı verilen ve kendi seçtiğiniz küçük gruplarla paylaşır. Arkasında bir hesap yoktur. Hiçbir zaman e-posta adresi, telefon numarası ya da parola vermezsiniz.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven\'ın kendi sunucuları da yoktur. Şifreli konum güncellemeleriniz, başkalarının işlettiği ve aktarıcı adı verilen bağımsız sunucular üzerinden geçer. Haven\'ın geliştiricileri konumunuzu göremez ve uygulamayı nasıl kullandığınıza dair hiçbir şey toplamaz.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'Verilerinizi isteyebileceğiniz kimse yok, çünkü kimse onları tutmuyor. Madalyonun öbür yüzü de şu: hesabınızı geri getirebilecek kimse de yok. Neleri yedeklemeniz gerektiğini “İki anahtarınız” bölümünde bulabilirsiniz.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'Uygulamada analitik, çökme bildirimi ya da reklam kodu bulunmaz. Haven açık kaynak olduğu için buna güvenmek zorunda değilsiniz; kendiniz doğrulayabilirsiniz.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven\'da anlık bildirim de yoktur; bu bilinçli bir seçimdir. Çevrelerinizdeki birinin size iletecek bir şeyi olduğunda bunun bir bildirim servisine haber verilmesi gerekirdi; bu da alışkanlıklarınız hakkında aktarıcıların gördüğünden fazlasını açığa çıkarırdı.';

  @override
  String get privacyYourKeysTitle =>
      'İki anahtarınız: biri gizli, biri paylaşmak için';

  @override
  String get privacyYourKeysSubtitle =>
      'Sizi tanımlayan şey ve yedeklemeniz gerekenler';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'Kullanıcı adı ve parola yerine bir anahtar çiftiniz olur. Gizli anahtar, sizin siz olduğunuzu kanıtlar. Açık anahtar ise başkalarının sizi bulmak ve davet etmek için kullandığı anahtardır.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Gizli anahtarınız yalnızca bu telefonda, işletim sisteminin koruduğu bir depolama alanında tutulur. Haven onu hiçbir yere göndermez — ne bir aktarıcıya ne de bize.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Açık anahtarınızı paylaşmanız güvenlidir. Her yerde paylaşabileceğiniz bir kullanıcı adı gibi çalışır. Onu paylaşmak nerede olduğunuzu açığa çıkarmaz.';

  @override
  String get privacyYourKeysMeansForYou =>
      'Bu kimliği korumak istiyorsanız gizli anahtarınızı yedekleyin. Onu Ayarlar → Kimlik → Gelişmiş bölümünde görebilirsiniz. Telefonu yedek almadan kaybederseniz kimliğiniz kalıcı olarak kaybolur ve kimse onu geri getiremez.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Gizli anahtarınızı ele geçiren herkes siz olur. Sizin adınıza çevrelere katılabilir ya da sizin adınıza içerik yayımlayabilir. Onu asla başka bir uygulamaya, bir mesaja ya da bir web sitesine yapıştırmayın.';

  @override
  String get privacyYourKeysDetailFormats =>
      'Bu çift bir secp256k1 anahtarıdır; standart Nostr biçimlerinde, açık anahtar npub1… ve gizli anahtar nsec1… olarak gösterilir. İmzalama uygulamanın içinde yapılır ve gizli baytlar her kullanımdan sonra bellekten silinir.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'Çevrelerinizin mesajlarını şifreleyen anahtarlar bu kimlik anahtarından ayrıdır ve yalnızca uygulamada tutulur. Bu ayrım bilinçlidir: sizi adlandıran anahtar, gönderdiklerinizi açan anahtar değildir.';

  @override
  String get privacyPublicProfileTitle =>
      'Adınız ve fotoğrafınız herkese açıktır';

  @override
  String get privacyPublicProfileSubtitle =>
      'Yalnızca çevrelerinize değil, herkese görünür';

  @override
  String get privacyPublicProfileIsPublic =>
      'Belirlediğiniz görünen ad ve fotoğraf, daha geniş Nostr ağına yayımlanır. Bunları yalnızca çevrelerinizdeki kişiler değil, herkes arayıp bulabilir.';

  @override
  String get privacyPublicProfileOnSave =>
      'Bu, onları kaydettiğiniz anda gerçekleşir. Bunları gizli tutan bir ayar yoktur ve bir adı yalnızca çevrelerinizle paylaşmanın bir yolu da yoktur.';

  @override
  String get privacyPublicProfilePseudonym =>
      'Yeni kurulumlar, sizinle ilgili hiçbir şey söylemeyen “Quiet Wanderer” gibi uydurma bir adla başlar. Bunu olduğu gibi bırakabilir ya da istediğiniz bir adla değiştirebilirsiniz.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Herkese göstermekte sakınca görmeyeceğiniz bir ad ve fotoğraf seçin. Tanınmamayı tercih ediyorsanız size verilen uydurma adı olduğu gibi bırakın ve fotoğraf eklemeyin.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Fotoğrafınızı sonradan kaldırmanız onu yayından çıkarmaz. Haven profilinizi boş bir profille değiştirir, ama görsel dosyası onu barındıran sunucuda kalır ve daha önce indirilmiş her kopya ortada dolaşmaya devam eder. Yayımladığınız her şeyi kalıcı sayın.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'Profil, kimlik anahtarınızla imzalanmış bir Nostr “kind 0” olayıdır. Fotoğraflar bir Blossom sunucusuna yüklenir — değiştirmediyseniz blossom.primal.net — ve bu sunucu görseli, açık anahtarınızı ve IP adresinizi görür.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Haven, yüklemeden önce resmi yeniden kodlar ve kameraların eklediği gizli verileri, fotoğrafın çekildiği GPS konumu da dahil, kaldırır. Bu burada önemlidir: aksi halde bir tatil fotoğrafı evinizin koordinatlarını taşıyabilir.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'Konumunuzun izlediği yol';

  @override
  String get privacyRelaysTitle => 'Aktarıcılar: mesajları ileten sunucular';

  @override
  String get privacyRelaysSubtitle =>
      'Güncellemeleriniz kimin bilgisayarlarından geçiyor';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven\'ın kendine ait bir sunucusu yok; bu yüzden güncellemeleriniz başkalarının sunucularından geçer. Bunlara aktarıcı denir: herkesin işletebileceği küçük, bağımsız sunucular. Bir aktarıcı şifreli bir mesajı kısa süre tutar, sonra çevreniz istediğinde onu iletir.';

  @override
  String get privacyRelaysWhyMany =>
      'Birden fazla aktarıcı kullandığınızda hiçbiri tek başına bağlantınızı kesemez. Biri çevrimdışı olursa diğerleri çalışmaya devam eder. Hangi aktarıcıları kullanacağınızı siz seçersiniz ve bunları istediğiniz zaman değiştirebilirsiniz.';

  @override
  String get privacyRelaysTwoLists =>
      'Haven sizin için iki liste tutar. Davetler, gelen kutusu aktarıcılarınıza ulaşır. Sizi davet etmek için gereken anahtarları ise başkaları KeyPackage aktarıcılarınızdan alır. Her çevrenin de kendi listesi vardır; o çevrenin şifreli güncellemeleri bu listeden geçer.';

  @override
  String get privacyRelaysMeansForYou =>
      'Burada yanlış yapıp riske girebileceğiniz bir şey yok: bir aktarıcı yalnızca şifreli veri görür. Ama erişilebilir en az bir aktarıcıya ihtiyacınız var; yoksa kimse sizi davet edemez ve çevreleriniz sessizleşir.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Haven, kendi listelerinizden bağımsız olarak, başkalarının profillerini ve anahtarlarını aramak için herkese açık az sayıda dizin aktarıcısına başvurur. Yalnızca kendinize ait özel aktarıcılar tanımlamış olsanız bile bunlara bağlanır. Bu aktarıcılar ağ adresinizi ve hangi hesapları sorduğunuzu görür.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'KeyPackage aktarıcı listeniz de başkalarının onu bulabilmesi için kimlik anahtarınızla imzalanarak ağa yayımlanır. Bu listeye özel bir aktarıcı eklerseniz onun adresi herkese açık olur ve sizinle ilişkilendirilir. Yalnızca tek bir çevrenin kendi listesinde kullanılan bir aktarıcı ise böyle duyurulmaz.';

  @override
  String get privacyEncryptionTitle => 'Şifreleme nasıl çalışır';

  @override
  String get privacyEncryptionSubtitle =>
      'Her çevrenin kendi anahtarları; biri katıldığında veya ayrıldığında ne değişir';

  @override
  String get privacyEncryptionPerCircle =>
      'Konumunuz, MLS adlı açık bir standart kullanılarak telefonunuzdan çıkmadan önce şifrelenir. Her çevre, kendi anahtarlarına sahip ayrı bir şifreli gruptur. Bir çevrenin dışındaki hiç kimse onun içinde gönderilenleri okuyamaz: ne bir aktarıcı, ne Haven, ne de üyesi olduğunuz başka bir çevre.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'Biri katıldığında çevre yeni bir anahtara geçer. Yeni üye, geldikten sonra gönderilenleri okuyabilir; gelişinden öncesine ait hiçbir şeyi okuyamaz. Haven yeni bir üyeye geçmiş konumları hiçbir zaman göndermez.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'Biri ayrıldığında ya da çıkarıldığında çevre yine yeni bir anahtara geçer. En fazla birkaç dakika içinde o kişi artık yeni hiçbir şeyi okuyamaz.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Anahtarlar yalnızca çevrenin üyeleri değiştiğinde değişir; belirli aralıklarla ya da zaman geçtikçe kendiliğinden değişmez. Bu değişiklikler arasında gönderilen her şey tek bir anahtarla korunur. Bu yüzden uzun süredir aynı kalan bir çevreden çıkardığınız biri, üye olduğu sırada kaydettiği mesajları — haftalar öncesine ait olanları bile — hâlâ açabilir. Ayrıldıktan sonra gönderilenlerin hiçbirini açamaz.';

  @override
  String get privacyEncryptionMeansForYou =>
      'Şifreleme sizi çevrelerinizin dışındaki herkese karşı korur. Bir zamanlar çevrenizin içinde olmuş birine karşı koruyamaz. Biriyle ilişkinizi tamamen kesmek istiyorsanız, onu eski bir çevreden çıkarmak yerine yeni bir çevre kurmak daha güvenlidir.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security), başka güvenli mesajlaşma uygulamalarının da kullandığı IETF standardıdır. Haven, Nostr ağına Marmot protokolü üzerinden bağlanır; bu protokol, MLS gruplarının aktarıcılar üzerinden nasıl taşındığını tanımlar. Her çevrenin imzalarken kullandığı anahtar, herkese açık Nostr kimlik anahtarınızdan ayrıdır.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Her anahtar dönemine epoch denir. Cihazınız yalnızca son birkaç epoch\'tan hâlâ yolda olan mesajları çözmeye yetecek kadar anahtar malzemesi tutar, sonra bunu atar. Haven\'ın eski mesajlarınızı ilke olarak bile geri getirememesinin nedeni budur.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'Üyeler neyi görür, aktarıcılar neyi görür';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'Paylaştığınız kişiler ve aradaki sunucular';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'Çevrelerinizdeki kişiler';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Bir çevredeki herkes haritada tam konumunuzu görür, yaklaşık bir alanı değil. Bazı üyelerle daha belirsiz, bazılarıyla kesin bir konum paylaşmanızı sağlayan bir ayar yoktur.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Haven açık olduğu ve bir çevrede bulunduğunuz sürece konumunuz birkaç dakikada bir kendiliğinden gönderilir. Duraklatma düğmesi yoktur. Değiştirebileceğiniz tek şey, uygulamadan çıktıktan sonra paylaşımın sürüp sürmeyeceğidir.';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Bir çevreye katılmak, açık anahtarınızı da her üyeye gösterir. Bunun üzerinden herkese açık profilinize ve o anahtarla şimdiye kadar yayımladığınız her şeye ulaşabilirler.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Bir üyenin profil fotoğrafı, o üyenin seçtiği bir sunucudan indirilir. Fotoğraf yüklenirken ağ adresiniz — dolayısıyla dünyanın kabaca hangi bölgesinde olduğunuz — o sunucuyu işleten kişiye açılır. Bu, siz hiçbir şeye dokunmadan kendiliğinden olur.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'Aktarıcı işletmecileri';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Aktarıcı işletmecileri konumunuzu, mesajlarınızı, çevrenizin adını ya da üye listesini okuyamazlar. Her mesaj onlara tek kullanımlık taze bir gönderim adresinden ulaşır; bu yüzden hangi üyenin gönderdiğini anlayamazlar.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'Buna karşılık ağ adresinizi, çevrimiçi olduğunuz zamanları ve trafiğinizin ne kadar büyük ve ne sıklıkta olduğunu görürler. Her çevre rastgele bir etiket taşır; bu sayede bir aktarıcı tek bir çevrenin mesajlarını bir arada toplayıp içinde kaç kişi olduğunu tahmin edebilir — hiçbirinin kim olduğunu öğrenmeden.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Bir çevreyi, ev adresinizi verebileceğiniz kişiler olarak düşünün. Aktarıcılara ve dışarıdakilere karşı şifreleme sizi korur; ağ adresi boşluğunu da bir VPN kapatır. Ekran görüntüsü alan bir üyeye karşı ise hiçbir şey korumaz.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'Bir çevrenin etiketi, o çevre var olduğu sürece aynı kalır; bu nedenle bir aktarıcı onun bütün mesajlarını süresiz olarak birbirine bağlayabilir. Bu, temeldeki protokolün bir özelliğidir; Haven\'ın değiştirebileceği bir şey değildir.';

  @override
  String get commonLearnMore => 'Daha fazla bilgi';

  @override
  String get relaySettingsBackendCaption =>
      'Haven\'ın kendine ait bir sunucusu yok. Şifreli güncellemeleriniz bağımsız sunuculardan geçer; bunlara aktarıcı denir ve ne konumunuzu ne de çevrelerinizde kimlerin olduğunu görebilirler.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'Ekran görüntüsü almak platforma bağlıdır ve iki platform bu konuda birbirinden farklıdır. Android\'de Haven, uygulamanın tamamında ekran görüntüsü almayı ve ekran kaydını engeller. iPhone\'da ise bunu yapamaz: Haven yalnızca uygulama değiştiricideki önizlemeyi bulanıklaştırır; bir üye ekranda görünenlerin görüntüsünü yine de alabilir.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven, aktarıcılardan konum mesajlarını yaklaşık dört dakika sonra silmelerini ister. Bu istek yalnızca bir tavsiyedir: bir aktarıcı onları daha uzun süre tutabilir. Davetlerin ise hiç geçerlilik süresi yoktur; gelen kutusu aktarıcınızda süresiz olarak kalabilirler.';

  @override
  String get privacyGroupTheLimitsHeading => 'Korumanın sınırları';

  @override
  String get privacyInferenceTitle =>
      'Yine de sizinle ilgili neler anlaşılabilir';

  @override
  String get privacyInferenceSubtitle => 'Şifrelemenin gizleyemediği izler';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'Şifreleme ne gönderdiğinizi gizler. Bir şey gönderdiğinizi gizleyemez. Bir mesajın etrafındaki örüntü — ne zaman çıktığı, ne kadar büyük olduğu, hangi sunuculara bağlı olduğunuz — üst veri olarak adlandırılır ve içerik görünmez olduğunda bile görünür kalır.';

  @override
  String get privacyInferenceActivityPattern =>
      'Bu örüntüden, kullandığınız bir aktarıcı kabaca ne zaman ve ne sıklıkta etkin olduğunuzu anlayabilir. Haven ayrıca yaklaşık yüz metreden fazla hareket ettiğinizde ek bir güncelleme gönderir; bu yüzden yeterince uzun bir kayıt, yolda mı olduğunuzu yoksa bir yerde mi kaldığınızı sezdirebilir — nerede olduğunuzu hiçbir zaman göstermeden.';

  @override
  String get privacyInferencePresence =>
      'Haven çalışırken aktarıcılarınıza açık bir bağlantı tutar; bu yüzden onlar da çevrimiçi olduğunuzu ve hangi çevreleri izlediğinizi görebilir. Güncellemelerin dakikalar değil saniyeler içinde gelmesinin bedeli bu.';

  @override
  String get privacyInferenceIpHeading => 'Ağ adresiniz';

  @override
  String get privacyInferenceIpAddress =>
      'Haven\'ın konuştuğu her sunucu, telefonunuzun bağlandığı ağ adresini görür: aktarıcılarınız, harita sağlayıcısı ve bir üyenin profil fotoğrafını barındıran sunucu. İnternet sağlayıcınız bu sunuculardan hangilerine ne zaman ulaştığınızı görür. Haven, kendi başına bunların hiçbirini gizlemek için bir şey yapmaz.';

  @override
  String get privacyInferenceVpnHeading => 'VPN kullanmalı mısınız?';

  @override
  String get privacyInferenceVpnHelps =>
      'Bir VPN, ağ adresinizin yerine kendi adresini koyar; böylece aktarıcılar ve diğer sunucular nereden bağlandığınızı artık görmez. Hangi sunuculara ulaştığınızı da internet sağlayıcınızdan gizler. Mullvad\'ı öneririz.';

  @override
  String get privacyInferenceVpnLimits =>
      'VPN her sorunun ilacı değildir. Çevre üyelerinizin gördüklerinde hiçbir şeyi değiştirmez ve konuştuğunuz bir aktarıcıdan trafiğinizin zamanlamasını ya da boyutunu gizlemez. Ayrıca birine güvenme ihtiyacınızı ortadan kaldırmaz; güveninizi yalnızca VPN şirketine kaydırır.';

  @override
  String get privacyInferenceMeansForYou =>
      'Sizi haritaya bir kişinin değil bir ağ işletmecisinin yerleştirmesinden kaygılanıyorsanız, ekleyebileceğiniz en yararlı tek şey bir VPN\'dir. Kaygılandığınız şey çevrelerinizdeki kişilerse, VPN hiç işe yaramaz.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven, güncellemeler arasındaki süreyi bilerek değiştirir; böylece kısa bir kayıtta düzenli bir ritim görünmez. Yine de saatler boyunca ortalama alındığında temeldeki güncelleme sıklığı tahmin edilebilir. Mesaj boyutları da dolgu ile eşitlenmez ve konum güncellemeleri dar bir boyut aralığına düştüğü için konum güncellemesi oldukları anlaşılabilir.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Bazı şeyler Haven\'ın çözebileceği alanın tamamen dışındadır. Aynı anda pek çok aktarıcıyı izleyebilen bir gözlemci ya da başkasının denetimine geçmiş kendi telefonunuz, buradaki hiçbir tasarım kararının düzeltebileceği şeyler değildir.';

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
  String get createCircleMemberAlreadyAdded => 'Üye zaten eklendi';

  @override
  String get createCircleNoIdInQr => 'QR kodunda geçerli bir kimlik bulunamadı';

  @override
  String get createCircleNoAccountFound => 'Haven hesabı bulunamadı';

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
      'Bu çevredeki herkes birbirinin konumunu ve görünen adını görebilir. Görünen adınız, Ayarlar → Kimlik bölümünde belirlediğiniz addır. Bu çevre, içinde bulunduğunuz diğerlerinden ayrı kalır; bu nedenle üyeleri diğer çevrelerinizi ya da kimlerin olduğunu göremez.';

  @override
  String get nameCircleCreateCta => 'Çevre Oluştur';

  @override
  String get nameCircleStageCreatingGroup => 'Güvenli grup oluşturuluyor...';

  @override
  String get nameCircleStageSendingInvites => 'Davetler gönderiliyor...';

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
  String addMemberTitle(String circleName) {
    return '$circleName çevresine ekle';
  }

  @override
  String get addMemberInfo =>
      'Yeni üyeler, daveti kabul ettiklerinde bu çevrenin şifreli konumlarını görebilir.';

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
  String addMemberPartialDelivery(int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Davetler gönderildi ($totalString davetten $sentString tanesi). Geri kalanın iletimi bekleniyor.';
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
  String get circleMemberInvitationPending => 'Davet Bekliyor';

  @override
  String get circleMemberNoRecentLocation => 'Yakın zamanlı konum yok';

  @override
  String get circleMemberRemoveTooltip => 'Çevreden kaldır';

  @override
  String get circleMemberAdmin => 'Yönetici';

  @override
  String get circleMemberHintPending => 'davet bekliyor';

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
  String get pendingMemberRemoveTooltip => 'Üyeyi kaldır';

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
  String get pendingMemberNeedsUpdate => 'Haven güncellemesi gerekiyor';

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
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString daha';
  }

  @override
  String get invitationStatusPending => 'Davet Bekliyor';

  @override
  String get invitationStatusActive => 'Etkin';

  @override
  String get invitationStatusDeclined => 'Reddedildi';

  @override
  String invitationStatusSemantics(String label) {
    return 'Davet durumu: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$circleName çevresine katılma daveti, davet eden $inviter, $countString üye';
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
  String invitationCardMemberCount(int count) {
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
  String get circleDetailsRelaysHeading => 'Bu çevre için aktarıcılar';

  @override
  String get circleDetailsNoRelays => '(kayıtlı yok)';

  @override
  String get circleDetailsRelaysNote =>
      'Bu aktarıcılar, çevre oluşturulurken seçilmiştir ve henüz kullanıcı tarafından düzenlenemez. Kişisel aktarıcı ayarlarınızdan bağımsızdır.';

  @override
  String get circleDetailsAddMember => 'Üye ekle';

  @override
  String get circleDetailsLeaveCircle => 'Çevreden Ayrıl';

  @override
  String get leaveCircleDialogTitle => 'Çevreden Ayrıl';

  @override
  String get leaveCircleDialogBody =>
      'Bu çevreden ayrılmak istediğinizden emin misiniz? Artık üyelerinden konum güncellemeleri almayacaksınız. Bu işlem geri alınamaz.';

  @override
  String get leaveCircleConfirm => 'Ayrıl';

  @override
  String get leaveCircleIdentityUnavailable => 'Kimlik kullanılamıyor';

  @override
  String get leaveCircleSuccess => 'Çevreden başarıyla ayrıldınız';

  @override
  String get leaveCircleError => 'Çevreden ayrılınamadı';

  @override
  String get circleBlockedBannerTitle => 'Bu çevre güncellenemiyor';

  @override
  String get circleBlockedBannerBody =>
      'Bu çevrenin şifrelemesinde bir sorun oluştu, bu yüzden Haven bu çevrede artık güncelleme gönderemiyor ya da alamıyor. Aşağıda en son bildiklerinizi görmeye devam edebilir ya da çevreden ayrılabilirsiniz.';

  @override
  String get legacyCircleBannerTitle =>
      'Bu çevrenin yeniden oluşturulması gerekiyor';

  @override
  String get legacyCircleBannerBody =>
      'Haven\'ın şifreleme motoru güncellendi, bu yüzden bu çevre artık kullanılamıyor. Aynı kişilerle konum paylaşmaya devam etmek için çevreyi yeniden oluşturun — onları tekrar davet etmeniz gerekecek.';

  @override
  String get legacyCircleRecreateCta => 'Çevreyi Yeniden Oluştur';

  @override
  String get legacyCircleRemoveCta => 'Kaldır';

  @override
  String get legacyCircleRemoveDialogTitle => 'Çevre kaldırılsın mı?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'Bu çevre artık kullanılamıyor ve listenizden kaldırılacak. Bu işlem, onun yerine oluşturacağınız yeni bir çevreyi etkilemez.';

  @override
  String get legacyCircleRemoveConfirm => 'Kaldır';

  @override
  String get legacyCutoverExplainerTitle => 'Haven güncellendi';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Kimliğiniz ve herkese açık profiliniz değişmedi — bunlar için yapmanız gereken bir şey yok.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Güvenliği artırmak için, bu çevrelerde tekrar konum paylaşabilmenizden önce çevrelerinizin yeniden oluşturulması ve üyelerinin yeniden davet edilmesi gerekiyor.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Anladım';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven, son güvenlik güncellemesinden kalan bazı verileri hâlâ temizliyor. Tekrar çevrimiçi olduğunuzda bu işlem otomatik olarak tamamlanacak.';

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
      'Bu işlem kimliğinizi kalıcı olarak siler. Geri kurtarmak istiyorsanız gizli anahtarınızı yedeklediğinizden emin olun.';

  @override
  String get identityAdvancedDeleteConfirm => 'Sil';

  @override
  String get identityAdvancedDeletedSnack => 'Kimlik silindi';

  @override
  String get identityAdvancedDeleteError =>
      'Kimlik silinemedi. Lütfen tekrar deneyin.';

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
      'Açık anahtarınız, paylaşılması güvenli bir kullanıcı adı gibi çalışır. İnsanlar sizi bir çevreye davet etmek için bu kodu tarar ya da açık anahtarınızı yapıştırır. Bunu paylaşmak konumunuzu açığa çıkaramaz; konumunuz yalnızca katıldığınız çevrelerin üyelerine görünür. Görünen adınız ve fotoğrafınız ise zaten herkese açık; bu kodu paylaşmak onlar hakkında yeni bir şey açığa çıkarmaz.';

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
  String keyDisplayCopiedToClipboard(String label) {
    return '$label panoya kopyalandı';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'gösteriliyor';

  @override
  String get keyDisplayStateHidden => 'gizli';

  @override
  String get keyDisplayHideTooltip => 'Gizle';

  @override
  String get keyDisplayRevealTooltip => 'Göster';

  @override
  String get keyDisplayCopyTooltip => 'Kopyala';

  @override
  String get keyDisplayCompactCopied => 'Anahtar panoya kopyalandı';

  @override
  String get keyDisplayCompactTapToCopy => 'Kopyalamak için dokunun';

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
      'Bu işlem, fotoğrafınızı herkese açık profilinizden kaldırır.';

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
  String get avatarPickerPhotoUpdated =>
      'Fotoğraf güncellendi — herkese açık Nostr profilinize yayımlandı.';

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
  String userLocationMarkerSemantics(String accuracy) {
    return 'Konum işaretiniz$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Doğruluk: $metersString metre';
  }

  @override
  String memberMarkerMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m';
  }

  @override
  String memberMarkerHoursShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h';
  }

  @override
  String memberMarkerDaysShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d';
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
  String memberMarkerHoursAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString saat önce',
      one: '1 saat önce',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerDaysAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString gün önce',
      one: '1 gün önce',
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
