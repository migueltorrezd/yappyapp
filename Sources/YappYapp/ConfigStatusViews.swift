import SwiftUI

// Small Brutal views for config-owned states: the LOCKED tag for settings an
// organization forces (MANAGED-PREFS), the one-time repair notice
// (CONFIG-RECOVERY, YA-26) and the login-item approval row (YA-60).

/// Ink chip that marks a setting the organization controls.
struct ManagedLockedTag: View {
    var body: some View {
        Text(ManagedPreferencesCopy.lockedTag)
            .brutalText(.control)
            .foregroundStyle(Brutal.paper)
            .padding(.horizontal, 8)
            .frame(minHeight: BrutalControl.height)
            .background(Brutal.ink)
            .accessibilityLabel(Text(L10n.tr("Locked by your organization")))
    }
}

enum ManagedLockPlacement {
    case trailing
    case below
}

private struct ManagedLockModifier: ViewModifier {
    let locked: Bool
    let placement: ManagedLockPlacement

    @ViewBuilder
    func body(content: Content) -> some View {
        if locked {
            switch placement {
            case .trailing:
                HStack(spacing: 8) {
                    content.disabled(true)
                    ManagedLockedTag()
                }
                .help(ManagedPreferencesCopy.lockedHelp)
                .accessibilityHint(Text(ManagedPreferencesCopy.lockedHelp))
            case .below:
                VStack(alignment: .leading, spacing: 6) {
                    content.disabled(true)
                    ManagedLockedTag()
                }
                .help(ManagedPreferencesCopy.lockedHelp)
                .accessibilityHint(Text(ManagedPreferencesCopy.lockedHelp))
            }
        } else {
            content
        }
    }
}

extension View {
    /// Disables the control and adds a LOCKED tag when a profile forces it.
    func managedLock(_ locked: Bool, placement: ManagedLockPlacement = .trailing) -> some View {
        modifier(ManagedLockModifier(locked: locked, placement: placement))
    }
}

/// Shown once after a damaged config.json was repaired.
struct ConfigRecoveryBanner: View {
    let notice: ConfigRecoveryNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("!")
                .brutalFont(size: 16, weight: .black, relativeTo: .headline)
                .foregroundStyle(Brutal.yellow)
                .frame(width: 24, height: 24)
                .background(Brutal.ink)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.ink)
                Text(notice.message)
                    .brutalFont(size: 10, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(L10n.tr("GOT IT"), action: onDismiss)
                .buttonStyle(.plain)
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(Brutal.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Brutal.card)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .brutalInteractive(
                    label: L10n.tr("Dismiss settings repair notice"),
                    hint: L10n.tr("Hides this notice"),
                    hitExpansion: 10
                )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.yellow)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("configRecoveryBanner.brutal")
    }
}

/// Under START AT LOGIN while macOS holds the login item for approval.
struct LoginItemApprovalRow: View {
    let onOpenLoginItems: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            BrutalCaption(LaunchAtLoginPresenter.needsApprovalLabel, tone: .warning)
            BrutalActionButton(
                title: LaunchAtLoginPresenter.openLoginItemsTitle,
                accessibilityLabel: L10n.tr("Open Login Items"),
                hint: L10n.tr("Opens System Settings so you can allow YappYapp to start at login"),
                action: onOpenLoginItems
            )
        }
    }
}

/// Top of the Models tab while a profile forces the model.
struct ManagedModelLockedRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ManagedLockedTag()
            Text(ManagedPreferencesCopy.modelLockedStatus.uppercased())
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.6)
                .foregroundStyle(Brutal.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(ManagedPreferencesCopy.lockedHelp)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("managedModelLocked.brutal")
    }
}

/// Replaces the Pet tab while a profile turns the pet off.
struct ManagedPetLockedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ManagedLockedTag()
            Text(ManagedPreferencesCopy.petLockedTitle)
                .brutalFont(size: 14, weight: .black, relativeTo: .headline)
                .kerning(1.2)
                .foregroundStyle(Brutal.ink)
            Text(ManagedPreferencesCopy.lockedHelp)
                .brutalFont(size: 9, weight: .bold, relativeTo: .caption)
                .foregroundStyle(Brutal.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("managedPetLocked.brutal")
    }
}
