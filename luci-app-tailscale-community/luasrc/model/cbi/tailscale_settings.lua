local tailscale = require("luci.tailscale").tailscale

local m, s, o

m = Map("tailscale", translate("Tailscale"), 
	translate("Tailscale is a mesh VPN solution that makes it easy to connect your devices securely. This configuration page allows you to manage Tailscale settings on your OpenWrt device."))

s = m:section(NamedSection, "settings", "settings", translate("Settings"))
s.anonymous = true
s.addremove = false

s:tab("general", translate("General Settings"))
s:tab("account", translate("Account Settings"))

-- --- General 选项卡 ---
o = s:taboption("general", Flag, "enable", translate("Enable"))
o.rmempty = false

o = s:taboption("general", ListValue, "fw_mode", translate("Firewall Mode"), translate("Select the firewall backend for Tailscale to use. Requires service restart to take effect."))
o:value("iptables", "iptables")
o:value("nftables", "nftables")
o.default = "iptables"
o.rmempty = false

o = s:taboption("general", Flag, "accept_routes", translate("Accept Routes"), translate("Allow accepting routes announced by other nodes."))
o.rmempty = false

o = s:taboption("general", Flag, "advertise_exit_node", translate("Advertise Exit Node"), translate("Declare this device as an Exit Node."))
o.rmempty = false

o = s:taboption("general", Flag, "exit_node_allow_lan_access", translate("Allow LAN Access"), translate("When using the exit node, access to the local LAN is allowed."))
o.rmempty = false

o = s:taboption("general", Flag, "runwebclient", translate("Enable Web Interface"), translate("Expose a web interface on port 5252 for managing this node over Tailscale."))
o.rmempty = false

o = s:taboption("general", Flag, "nosnat", translate("Disable SNAT"), translate("Disable Source NAT (SNAT) for traffic to advertised routes. Most users should leave this unchecked."))
o.rmempty = false

o = s:taboption("general", Flag, "shields_up", translate("Shields Up"), translate("When enabled, blocks all inbound connections from the Tailscale network."))
o.rmempty = false

o = s:taboption("general", Flag, "ssh", translate("Enable Tailscale SSH"), translate("Allow connecting to this device through the SSH function of Tailscale."))
o.rmempty = false

o = s:taboption("general", Flag, "disable_magic_dns", translate("Disable MagicDNS"), translate("Use system DNS instead of MagicDNS."))
o.rmempty = false

-- Exit Node 节点选择（动态调 ubus 获取 peer 节点）
o = s:taboption("general", ListValue, "exit_node", translate("Exit Node"), translate("Select an exit node from the list. If enabled, Allow LAN Access is enabled implicitly."))
o:value("", translate("None"))
o.rmempty = true

local status_raw = tailscale.get_status()
if status_raw and status_raw.peers then
	for _, peer in pairs(status_raw.peers) do
		if peer.exit_node_option then
			local primaryIp = string.match(peer.ip or "", "([^<]+)") or peer.ip
			local label = peer.hostname and (peer.hostname .. " (" .. primaryIp .. ")") or primaryIp
			o:value(primaryIp, label)
		end
	end
end

-- Advertise Routes 动态列表
o = s:taboption("general", DynamicList, "advertise_routes", translate("Advertise Routes"), translate("Advertise subnet routes behind this device. Select from the detected subnets below or enter custom routes (comma-separated)."))
o.rmempty = true
local subroutes_raw = tailscale.get_subroutes()
if subroutes_raw and subroutes_raw.routes then
	for _, route in ipairs(subroutes_raw.routes) do
		o:value(route, route)
	end
end

-- 自动配置防火墙按钮
o = s:taboption("general", Button, "_setup_firewall", translate("Auto Configure Firewall"))
o.description = translate("Essential configuration for Subnet Routing (Site-to-Site) and Exit Node features.") .. "<br>" ..
				translate("It automatically creates the tailscale interface, sets up firewall zones for LAN <-> Tailscale forwarding,") .. "<br>" ..
				translate("and enables Masquerading and MSS Clamping (MTU fix) to ensure stable connections.")
o.inputstyle = "action"
o.write = function(self, section)
	local res = tailscale.setup_firewall()
	if res and res.message then
		m.message = res.message
	else
		m.message = translate("Firewall configuration applied.")
	end
end

-- 站点到站点提示信息
o = s:taboption("general", DummyValue, "_help_title")
o.rawhtml = true
o.value = [[
<div class="cbi-value" style="margin-top: 1em; border-top: 1px solid #ccc; padding-top: 1em;">
	<label class="cbi-value-title" style="font-weight: bold;">%s</label>
	<div class="cbi-value-field" style="line-height: 1.6em; font-size: 95%%; color: #555;">
		%s<br>
		%s<br>
		%s<br>
		<strong style="color: #d9534f;">%s</strong>
	</div>
</div>
]] % {
	translate('How to enable Site-to-Site?'),
	translate('1. Select "Accept Routes" (to access remote devices).'),
	translate('2. In "Advertise Routes", select your local subnet (to allow remote devices to access this LAN).'),
	translate('3. Click "Auto Configure Firewall" (to allow traffic forwarding).'),
	translate('[Important] Log in to the Tailscale admin console and manually enable "Subnet Routes" for this device.'),
}
local str = ""


-- --- Account 选项卡 ---
if status_raw.status == "logout" then
	o = s:taboption("account", Button, "_login", translate("Login"), translate("Click to get a login URL for this device.") .. "<br>" .. translate("If the timeout is displayed, you can refresh the page and click Login again."))
	o.inputstyle = "apply"
	o.write = function(self, section)
		local login_server = m:get(section, "custom_login_url") or ""
		local auth_key = m:get(section, "custom_login_AuthKey") or ""
		local res = tailscale.do_login({ loginserver = login_server, loginserver_authkey = auth_key })
		if res and res.url then
			luci.http.redirect(res.url)
		else
			m.errmsg = translate("Failed to get login URL: Invalid response from server.")
		end
	end

	o = s:taboption("account", Value, "custom_login_url", translate("Custom Login Server"), translate("Optional: Specify a custom control server URL (e.g., a Headscale instance, https://example.com). Leave blank for default Tailscale control plane."))
	o.rmempty = true

	o = s:taboption("account", Value, "custom_login_AuthKey", translate("Custom Login Server Auth Key"), translate("Optional: Specify an authentication key for the custom control server. Leave blank if not required."))
	o.rmempty = true
end

if status_raw.status == "running" then
	o = s:taboption("account", Button, "_logout", translate("Logout"), translate("Click to Log out account on this device.") .. "<br>" .. translate("Disconnect from Tailscale and expire current node key."))
	o.inputstyle = "apply"
	o.write = function(self, section)
		local res = tailscale.do_logout()
		if res.success then
			m.message = translate("Successfully logged out.")
		else
			m.errmsg = res.error
		end
	end
end

-- ==========================================
-- 3. 保存并应用时的同步逻辑
-- ==========================================
m.on_after_commit = function(self)
	local data = self:get("settings") or {}
	local res = tailscale.set_settings(data)
end

return m
