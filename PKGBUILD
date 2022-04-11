# Maintainer: Ken Rendell L. Caoile <kaoile.cenrendell@gmail.com>

pkgname='logins-manager-git'
pkgver=r6.00a4856
pkgrel=1
epoch=1
pkgdesc=''
arch=('x86_64')
url='https://github.com/kenrendell/logins-manager'
license=('GPL3')
depends=('gnupg' 'git' 'oath-toolkit' 'jq' 'fzf' 'wl-clipboard' 'lua')
makedepends=('git')
provides=('logins' 'gen-passwd')
source=("${pkgname}::git+https://github.com/kenrendell/logins-manager.git")
md5sums=('SKIP')

pkgver() { cd "${srcdir}/${pkgname}" && printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"; }

package() { cd "${srcdir}/${pkgname}" && make DESTDIR="$pkgdir" PREFIX='/usr' install; }
