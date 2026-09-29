include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale-community
PKG_MAINTAINER:=Tokisaki-Galaxy <moebest@outlook.jp>

LUCI_TITLE:=LuCI support for Tailscale
LUCI_DEPENDS:=+luci-compat +ip-full +tailscale
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
