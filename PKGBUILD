pkgname=hyprland-zoom
pkgver=0.1.0
pkgrel=7
pkgdesc='Shell-based zoom controller and bindings for Hyprland'
arch=('any')
url='https://github.com/artibex/hyprland-zoom'
license=('MIT')
depends=('bash' 'hyprland')
backup=('etc/zoomctl.conf')
install='install/post_install.sh'
source=()
sha256sums=()

package() {
  install -Dm755 "$startdir/src/zoomctl" "$pkgdir/usr/bin/zoomctl"

  install -Dm644 "$startdir/src/lib/config.sh" "$pkgdir/usr/share/hyprland-zoom/lib/config.sh"
  install -Dm644 "$startdir/src/lib/hyprland.sh" "$pkgdir/usr/share/hyprland-zoom/lib/hyprland.sh"
  install -Dm644 "$startdir/src/lib/math.sh" "$pkgdir/usr/share/hyprland-zoom/lib/math.sh"
  install -Dm644 "$startdir/src/lib/state.sh" "$pkgdir/usr/share/hyprland-zoom/lib/state.sh"
  install -Dm644 "$startdir/src/lib/setup.sh" "$pkgdir/usr/share/hyprland-zoom/lib/setup.sh"

  install -Dm644 "$startdir/config/defaults.conf" "$pkgdir/etc/zoomctl.conf"
  install -Dm644 "$startdir/config/hyprland-bindings.conf" "$pkgdir/usr/share/hyprland-zoom/hyprland-bindings.conf"

  install -Dm644 "$startdir/README.md" "$pkgdir/usr/share/doc/hyprland-zoom/README.md"
  install -Dm644 "$startdir/Agent.md" "$pkgdir/usr/share/doc/hyprland-zoom/Agent.md"
  install -Dm644 "$startdir/docs/usage.md" "$pkgdir/usr/share/doc/hyprland-zoom/usage.md"
  install -Dm644 "$startdir/docs/packaging.md" "$pkgdir/usr/share/doc/hyprland-zoom/packaging.md"
  install -Dm644 "$startdir/zoom-mvp.conf" "$pkgdir/usr/share/doc/hyprland-zoom/examples/zoom-mvp.conf"
}