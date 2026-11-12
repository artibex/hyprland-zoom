# Maintainer: artibex <korbinian.maag@gmail.com>
#
# Builds from the repository checkout (there is no source tarball): `package()` runs the
# Makefile of the checkout. makepkg would use ./src as $srcdir, which is the code directory of
# this repository, so build with a separate directory: `BUILDDIR=/tmp/hzoom-build makepkg -f`
# (see docs/packaging.md). `pkgver` must equal the VERSION file (checked by tests/repo).
pkgname=hyprland-zoom
pkgver=0.2.0
pkgrel=1
pkgdesc='Accessibility screen zoom for Hyprland: pointer tracking, colour filters, settings app'
arch=('any')
url='https://github.com/artibex/hyprland-zoom'
license=('MIT')
depends=(
  'bash'
  'coreutils'
  'gawk'
  'glib2'
  'grep'
  'gtk4'
  'hicolor-icon-theme'
  'hyprland>=0.55'
  'libadwaita'
  'python'
  'python-gobject'
  'sed'
  'util-linux'
)
checkdepends=('lua')
optdepends=(
  'hyprpm: build and load the optional hyprzoom plugin (adjustable pointer margin)'
  'cmake: plugin build through hyprpm'
  'meson: plugin build through hyprpm'
  'cpio: plugin build through hyprpm'
  'gcc: plugin build through hyprpm'
  'pkgconf: plugin build through hyprpm'
)
backup=('etc/zoomctl.conf')
install='install/post_install.sh'
source=()
sha256sums=()

# check — run the fast suites (bash suites, shellcheck when present, Lua unit tests).
check() {
  cd "$startdir"
  make test-core
}

# package — install the whole tree below /usr (and /etc/zoomctl.conf) into the package root.
package() {
  cd "$startdir"
  make install DESTDIR="$pkgdir" PREFIX=/usr
}
