// About: version, source code, and the license / credits notice.
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
  static const String _githubUrl = 'https://github.com/rodri2482/ClearCut';
  static const String _licenseUrl = 'https://www.gnu.org/licenses/gpl-3.0.html';

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

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
                icon: Icons.code_rounded,
                title: context.l10n.github,
                subtitle: context.l10n.viewTheSourceCode,
                onTap: () => _open(_githubUrl),
              ),
              SettingsTile(
                icon: Icons.help_outline_rounded,
                title: context.l10n.howItWorks,
                subtitle: context.l10n.howItWorksSubtitle,
                onTap: () => _push(const HowItWorksScreen()),
              ),
              SettingsTile(
                icon: Icons.gavel_rounded,
                title: 'License',
                subtitle: 'GNU General Public License v3.0',
                onTap: () => _open(_licenseUrl),
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
          const SizedBox(height: 24),
          // Required notice (GPL-3.0 §5): this is a modified version, under
          // the GPL, with no warranty. Credits the projects it is built on.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '$kAppName is free software under the GNU GPL v3.0 and comes '
              'with ABSOLUTELY NO WARRANTY. It is a modified version of '
              'Zangetsu (GPL-3.0) and includes code from NoFlix (Apache-2.0). '
              'See LICENSE and NOTICE.md in the source code.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                height: 1.4,
              ),
            ),
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
