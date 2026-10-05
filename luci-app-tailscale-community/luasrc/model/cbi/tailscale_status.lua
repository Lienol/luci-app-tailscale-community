local tailscale = require("luci.tailscale").tailscale

local data = tailscale.get_status()

m = Map("tailscale", translate("Tailscale"))

s = m:section(SimpleSection, translate("Status"))

o = s:option(DummyValue, "_status", translate("Service Status"))
o.rawhtml = true
o.value = data.status == "running" and ('<span style="color:green;">' .. translate("Running") .. '</span>') or ('<span style="color:red;">' .. translate("Not Running") .. '</span>')

if data.status == "running" then
	o = s:option(DummyValue, "_version", translate("Version"))
	o.value = data.version

	o = s:option(DummyValue, "_tun", translate("TUN Mode"))
	o.value = data.TUNMode and translate('Enabled') or translate('Disabled')

	o = s:option(DummyValue, "_ipv4", translate("Tailscale IPv4"))
	o.value = data.ipv4

	o = s:option(DummyValue, "_ipv6", translate("Tailscale IPv6"))
	o.value = data.ipv6 or translate("N/A")

	if next(data.peers) then
		s_peers = m:section(Table, "peers", "")
		s_peers.anonymous = true
		s_peers.sortable = false
		function s_peers.cfgsections(self)
			local sections = {}
			for k, v in pairs(data.peers) do
				sections[#sections+1] = tostring(k)
			end
			return sections
		end

		local online_col = s_peers:option(DummyValue, "online", translate("Status"))
		online_col.rawhtml = true
		online_col.value = function(self, section, value)
			local peer = data.peers[section]
			return peer.origin.Online and
				'<span style="color:green;" title="'..translate("Online")..'">●</span>' or
				'<span style="color:gray;" title="'..translate("Offline")..'">○</span>'
		end

		local hostname_col = s_peers:option(DummyValue, "hostname", translate("Hostname"))
		hostname_col.rawhtml = true
		hostname_col.value = function(self, section, value)
			local peer = data.peers[section]
			return string.format("<strong>%s</strong><br /><small>%s</small>", peer.origin.HostName, peer.origin.DNSName)
		end

		local ips_col = s_peers:option(DummyValue, "ips", translate("Tailscale IPs"))
		ips_col.rawhtml = true
		ips_col.value = function(self, section, value)
			local peer = data.peers[section]
			return table.concat(peer.origin.TailscaleIPs or {}, "<br />")
		end

		local os_col = s_peers:option(DummyValue, "os", translate("OS"))
		os_col.rawhtml = true
		os_col.value = function(self, section, value)
			local peer = data.peers[section]
			return peer.origin.OS
		end

		--[[
		local connection_col = s_peers:option(DummyValue, "connection", translate("Connection Info"))
		connection_col.rawhtml = true
		connection_col.value = function(self, section, value)
			local peer = data.peers[section]
			if not peer.origin.Online then
				return translate("N/A")
			end

			local linkadress = peer.linkadress or "-"
			if type(linkadress) == "string" and #linkadress == 3 then
				linkadress = linkadress:lower()
			end

			if linkadress:match("direct") then
				return ('<span style="color:green;" title="%s">%s</span>'):format(linkadress, translate("Direct"))
			elseif linkadress:match("relay") then
				local relay_node = linkadress:match("%((%S+)%)")
				local display_text = relay_node and ("Relay (%s)"):format(relay_node) or translate("Relay")
				return ('<span style="color:orange;" title="%s">%s</span>'):format(linkadress, display_text)
			elseif linkadress == "-" then
				return translate("ONLINE BUT UNKNOWN")
			elseif linkadress:match("^idle") then
				return ('<span style="color:blue;" title="%s">%s</span>'):format(linkadress, translate("Idle"))
			else
				return linkadress
			end
		end
		]]--

		function formatBytes(bytes)
			if not bytes or bytes < 0 then
				return "0"
			end
			bytes = tonumber(bytes)

			local units = {"B", "KB", "MB", "GB"}
			local index = 1

			while bytes >= 1024 and index < #units do
				bytes = bytes / 1024
				index = index + 1
			end

			if index == 1 then
				return string.format("%d %s", bytes, units[index])
			else
				return string.format("%.2f %s", bytes, units[index])
			end
		end

		local rx_col = s_peers:option(DummyValue, "rx", translate("RX"))
		rx_col.value = function(self, section, value)
			return formatBytes(data.peers[section].origin.RxBytes)
		end

		local tx_col = s_peers:option(DummyValue, "tx", translate("TX"))
		tx_col.value = function(self, section, value)
			return formatBytes(data.peers[section].origin.TxBytes)
		end

		local function format_last_seen(timestr)
			if not timestr or timestr:match("^0001") then return translate("Never") end
			local y, M, d, h, m = timestr:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
			if y then return string.format("%s-%s-%s %s:%s", y, M, d, h, m) end
			return timestr
		end

		local lastseen_col = s_peers:option(DummyValue, "lastseen", translate("Last Seen"))
		lastseen_col.value = function(self, section, value)
			local peer = data.peers[section]
			return peer.origin.Online and translate("Now") or format_last_seen(peer.origin.LastSeen)
		end
	end
end

return m