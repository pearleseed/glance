import Image from "next/image";

export function PrivacyNotice() {
  return (
    <aside
      className="glance-shell glance-privacy-notice"
      aria-label="Important security information"
    >
      <Image
        src="/media/security/touchid.svg"
        alt=""
        width={113}
        height={111}
      />
      <p>Glance will never be as secure as Apple’s Touch ID or Face ID.</p>
      <p>
        Mac webcams lack 3D depth sensors. Glance is a convenience layer for
        unlock, App Lock, and opt-in sudo — not a hardware security upgrade.
      </p>
    </aside>
  );
}
