// About: version and the in-app guide. Social, source and legal rows are not
// shown here.
part of 'settings_screen.dart';

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

class AboutSettingsScreen extends StatefulWidget {
  const AboutSettingsScreen({super.key});

  @override
  State<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends State<AboutSettingsScreen> {
  void _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.about),
      body: ListView(
        padding: const EdgeInsets.only(top: 24, bottom: 30),
        children: [
          const _ProfileCard(),
          const SizedBox(height: 24),
          SettingsCard(
            children: [
              SettingsTile(
                autofocus: true,
                icon: Icons.system_update_rounded,
                title: context.l10n.checkForUpdates,
                subtitle: context.l10n.checkForUpdatesSubtitle,
                onTap: () => maybeShowUpdateDialog(context, manual: true),
              ),
              SettingsTile(
                icon: Icons.help_outline_rounded,
                title: context.l10n.howItWorks,
                subtitle: context.l10n.howItWorksSubtitle,
                onTap: () => _push(const HowItWorksScreen()),
              ),
            ],
          ),
          if (sl.isRegistered<AppMode>() &&
              sl<AppMode>().isTv &&
              kExoSpikeEnabled)
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.speed_rounded,
                  title: context.l10n.exoplayerSpikeDev,
                  subtitle: context.l10n.sp0TestSurfaceViewPlaybackSmoothness,
                  onTap: () => _push(const TvExoSpikeScreen()),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The app header: the logo mark, name and version.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 6),
        Image.asset('assets/icon/logo_mark.png', height: 96),
        const SizedBox(height: 16),
        Text(kAppName, style: AppText.largeTitle.copyWith(fontSize: 25)),
        const SizedBox(height: 3),
        Text(
          'v$kAppVersion',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 6),
        Text(
          'Anime, movies & series — ad-free',
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
