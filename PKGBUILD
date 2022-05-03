# Maintainer: Ken Rendell L. Caoile <kaoile.cenrendell@gmail.com>

pkgname='logins-manager-git'
pkgver='VERSION'
pkgrel=1
pkgdesc=''
arch=('x86_64')
url='https://github.com/kenrendell/logins-manager'
license=('GPL3')
depends=('gnupg' 'git' 'openssl' 'jq' 'fzf' 'wl-clipboard' 'lua')
makedepends=('git')
provides=('logins' 'gen-random')
source=("${pkgname%-git}::git+https://github.com/kenrendell/logins-manager.git")
md5sums=('SKIP')

pkgver() { cd "${srcdir}/${pkgname%-git}" && printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"; }

package() { cd "${srcdir}/${pkgname%-git}" && make DESTDIR="$pkgdir" PREFIX='/usr' install; }
