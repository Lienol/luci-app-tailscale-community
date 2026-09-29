module("luci.controller.tailscale", package.seeall)

function index()
	if not nixio.fs.access("/usr/sbin/tailscale") and not nixio.fs.access("/usr/bin/tailscale") then
		return
	end
	
	e = entry({"admin", "services", "tailscale"}, alias("admin", "services", "tailscale", "status"), _("Tailscale"), 90)
	e.dependent = false
    e.acl_depends = { "luci-app-tailscale-community" }

	entry({"admin", "services", "tailscale", "status"}, cbi("tailscale_status"), _("Status"), 1)
	entry({"admin", "services", "tailscale", "settings"}, cbi("tailscale_settings"), _("Settings"), 2)
end
