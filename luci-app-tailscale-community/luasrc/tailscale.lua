module("luci.tailscale", package.seeall)

local uci = require("luci.model.uci").cursor()
local json = require("luci.jsonc")
local sys = require("luci.sys")
local nixio = require("nixio")

-- 辅助函数：执行 shell 命令并获取 stdout 和 exit_code
local function exec(cmd)
	local pp = io.popen(cmd .. " 2>&1")
	if not pp then
		return { code = -1, stdout = {}, stderr = "Failed to execute: " .. cmd }
	end

	local stdout_content = {}
	for line in pp:lines() do
		table.insert(stdout_content, line)
	end
	local success, exit_type, code = pp:close()
	local exit_code = (type(code) == "number") and code or (success and 0 or 1)

	local stderr_content = ""
	if exit_code ~= 0 then
		stderr_content = table.concat(stdout_content, "\n")
	end

	return { code = exit_code, stdout = stdout_content, stderr = stderr_content }
end

-- 辅助函数：转义 shell 参数
local function shell_quote(s)
	if not s or s == "" then return "''" end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- 辅助函数：字符串 Trim
local function trim(s)
	return (s or ""):match("^%s*(.-)%s*$")
end

-- 辅助函数：Base64 解码
local function b64dec(data)
	return nixio.bin.b64decode(data or "")
end

local methods = {}

methods.get_status = function()
	local data = {
		status = "",
		version = "",
		TUNMode = false,
		health = "",
		ipv4 = "Not running",
		ipv6 = "",
		domain_name = "",
		peers = {}
	}

	if sys.call("busybox top -bn1 | grep -v grep | grep 'tailscale' >/dev/null") ~= 0 then
		data.status = "not_run"
		return data
	end

	-- 检查可执行文件是否存在
	if nixio.fs.access("/usr/sbin/tailscale") or nixio.fs.access("/usr/bin/tailscale") then
		-- pass
	else
		data.status = "not_installed"
		return data
	end

	local status_json_output = exec("tailscale status --json")
	local peer_map = {}

	if status_json_output.code == 0 and #status_json_output.stdout > 0 then
		local raw_json = table.concat(status_json_output.stdout, "\n")
		local status_data = json.parse(raw_json)

		if status_data then
			data.version = status_data.Version or "Unknown"
			data.health = (status_data.Health and #status_data.Health > 0) and status_data.Health[1] or ""
			data.TUNMode = status_data.TUN

			if status_data.BackendState == "Running" then data.status = "running" end
			if status_data.BackendState == "NeedsLogin" then data.status = "logout" end

			if status_data.Self and status_data.Self.TailscaleIPs then
				data.ipv4 = status_data.Self.TailscaleIPs[1] or "No IP assigned"
				data.ipv6 = status_data.Self.TailscaleIPs[2] or ""
			end

			if status_data.CurrentTailnet then
				data.domain_name = status_data.CurrentTailnet.Name or ""
			end

			-- 处理 Peers
			if status_data.Peer and next(status_data.Peer) then
				for _, p in pairs(status_data.Peer) do
					local ips = table.concat(p.TailscaleIPs or {}, "<br>")
					local dns_name = p.DNSName or ""
					local hostname = dns_name:split(".")[1] or ""

					peer_map[tostring(p.ID)] = {
						ip = ips,
						dnsname = dns_name,
						hostname = hostname,
						ostype = p.OS,
						online = p.Online,
						linkadress = (not p.CurAddr or p.CurAddr == "") and p.Relay or p.CurAddr,
						lastseen = p.LastSeen,
						exit_node = not not p.ExitNode,
						exit_node_option = not not p.ExitNodeOption,
						tx = p.TxBytes or "",
						rx = p.RxBytes or "",
						origin = p
					}
				end
			end
		end
	end

	data.peers = peer_map
	return data
end

methods.get_settings = function()
	local settings = {}
	uci:load("tailscale")
	local state_file_path = uci:get("tailscale", "settings", "state_file") or "/etc/tailscale/tailscaled.state"

	if nixio.fs.access(state_file_path) then
		local f = io.open(state_file_path, "r")
		if f then
			local state_content = f:read("*a")
			f:close()

			local state_data = json.parse(state_content)
			if state_data and state_data._profiles then
				local profiles_b64 = state_data._profiles
				local profiles_data = json.parse(b64dec(profiles_b64) or "")

				local profiles_key = nil
				if profiles_data then
					for k, _ in pairs(profiles_data) do
						profiles_key = k
						break
					end
				end

				if profiles_key then
					profiles_key = "profile-" .. profiles_key
					local profile_json_b64 = state_data[profiles_key]
					local status_data = json.parse(b64dec(profile_json_b64) or "")

					if status_data then
						settings.accept_routes = status_data.RouteAll or false
						settings.advertise_exit_node = status_data.AdvertiseExitNode or false
						settings.advertise_routes = status_data.AdvertiseRoutes or {}
						settings.exit_node = status_data.ExitNodeID or ""
						settings.exit_node_allow_lan_access = status_data.ExitNodeAllowLANAccess or false
						settings.shields_up = status_data.ShieldsUp or false
						settings.ssh = status_data.RunSSH or false
						settings.runwebclient = status_data.RunWebClient or false
						settings.nosnat = status_data.NoSNAT or false
						settings.disable_magic_dns = not (status_data.CorpDNS or false)
						
						local fw_mode = uci:get("tailscale", "settings", "fw_mode") or "nftables"
						settings.fw_mode = fw_mode:split(" ")[1] or "nftables"
					end
				end
			end
		end
	end
	return settings
end

methods.do_login = function(form_data)
	if not form_data or type(form_data) ~= "table" then
		return { error = "Missing or invalid form_data parameter. Please provide login data." }
	end

	local status = methods.get_status()
	if status.status ~= "logout" then
		return { error = "Tailscale is already logged in and running." }
	end

	--结束旧进程
	sys.call("busybox top -bn1 | grep -v 'grep' | grep 'tailscale login' | awk '{print $1}' | xargs kill -9 2>/dev/null")

	local loginargs = {}
	local loginserver = trim(form_data.loginserver or "")
	local loginserver_authkey = trim(form_data.loginserver_authkey or "")

	if loginserver ~= "" then
		table.insert(loginargs, "--login-server " .. shell_quote(loginserver))
		if loginserver_authkey ~= "" then
			table.insert(loginargs, "--auth-key " .. shell_quote(loginserver_authkey))
		end
	end

	local login_cmd = "tailscale login " .. table.concat(loginargs, " ")
	-- 后台非阻塞运行
	os.execute(login_cmd .. " >/dev/null 2>&1 &")

	-- 循环轮询状态获取 URL
	local max_attempts = 15
	for i = 1, max_attempts do
		local tresult = exec("tailscale status")
		for _, line in ipairs(tresult.stdout) do
			local trline = trim(line)
			if trline:find("http") then
				for part in trline:gmatch("%S+") do
					if part:find("http") then
						return { url = part }
					end
				end
			end
		end
		nixio.nanosleep(2, 0) -- 睡眠 2 秒
	end

	return { error = "Could not retrieve login URL from tailscale command after 30 seconds." }
end

methods.do_logout = function()
	--结束旧进程
	sys.call("busybox top -bn1 | grep -v 'grep' | grep 'tailscale login' | awk '{print $1}' | xargs kill -9 2>/dev/null")
	sys.call("busybox top -bn1 | grep -v 'grep' | grep 'tailscale logout' | awk '{print $1}' | xargs kill -9 2>/dev/null")

	local status = methods.get_status()
	if status.status ~= "running" then
		return { error = "Tailscale is not running. Cannot perform logout." }
	end

	local logout_result = exec("tailscale logout")
	if logout_result.code ~= 0 then
		return { error = "Failed to logout: " .. logout_result.stderr }
	end
	return { success = true }
end

methods.get_subroutes = function()
	local cmd = "ip -j route"
	local result = exec(cmd)
	local subnets = {}

	if result.code == 0 and #result.stdout > 0 then
		local raw_json = table.concat(result.stdout, "\n")
		local routes_json = json.parse(raw_json)

		if routes_json then
			for _, route in ipairs(routes_json) do
				if route.dst and route.dst ~= "default" and route.scope == "link" and route.dst:find("%.") then
					table.insert(subnets, route.dst)
				end
			end
		end
	end
	return { routes = subnets }
end

methods.setup_firewall = function()
	local ok, err = pcall(function()
		uci:load("network")
		uci:load("firewall")

		local changed_network = false
		local changed_firewall = false

		-- 1. 配置接口 Network Interface
		local net_ts = uci:get("network", "tailscale")
		if not net_ts then
			uci:set("network", "tailscale", "interface")
			uci:set("network", "tailscale", "proto", "none")
			uci:set("network", "tailscale", "device", "tailscale0")
			changed_network = true
		else
			local current_dev = uci:get("network", "tailscale", "device")
			if current_dev ~= "tailscale0" then
				uci:set("network", "tailscale", "device", "tailscale0")
				changed_network = true
			end
		end

		-- 2. 配置防火墙 Firewall Zone
		local fw_all = uci:get_all("firewall")
		local ts_zone_section = nil
		local fwd_lan_to_ts = false
		local fwd_ts_to_lan = false

		for sec_key, s in pairs(fw_all) do
			if s[".type"] == "zone" and s["name"] == "tailscale" then
				ts_zone_section = sec_key
			end
			if s[".type"] == "forwarding" then
				if s.src == "lan" and s.dest == "tailscale" then fwd_lan_to_ts = true end
				if s.src == "tailscale" and s.dest == "lan" then fwd_ts_to_lan = true end
			end
		end

		if not ts_zone_section then
			local zid = uci:add("firewall", "zone")
			uci:set("firewall", zid, "name", "tailscale")
			uci:set("firewall", zid, "input", "ACCEPT")
			uci:set("firewall", zid, "output", "ACCEPT")
			uci:set("firewall", zid, "forward", "ACCEPT")
			uci:set("firewall", zid, "masq", "1")
			uci:set("firewall", zid, "mtu_fix", "1")
			uci:set("firewall", zid, "network", { "tailscale" })
			changed_firewall = true
		else
			local nets = uci:get("firewall", ts_zone_section, "network")
			local net_list = {}
			local has_ts_net = false

			if type(nets) == "table" then
				net_list = nets
			elseif type(nets) == "string" then
				net_list = { nets }
			end

			for _, n in ipairs(net_list) do
				if n == "tailscale" then
					has_ts_net = true
					break
				end
			end

			if not has_ts_net then
				table.insert(net_list, "tailscale")
				uci:set("firewall", ts_zone_section, "network", net_list)
				changed_firewall = true
			end
		end

		-- 3. 配置转发 Forwarding
		if not fwd_lan_to_ts then
			local fid = uci:add("firewall", "forwarding")
			uci:set("firewall", fid, "src", "lan")
			uci:set("firewall", fid, "dest", "tailscale")
			changed_firewall = true
		end

		if not fwd_ts_to_lan then
			local fid = uci:add("firewall", "forwarding")
			uci:set("firewall", fid, "src", "tailscale")
			uci:set("firewall", fid, "dest", "lan")
			changed_firewall = true
		end

		-- 4. 保存提交
		if changed_network then
			uci:save("network")
			uci:commit("network")
			exec("/etc/init.d/network reload")
		end

		if changed_firewall then
			uci:save("firewall")
			uci:commit("firewall")
			exec("/etc/init.d/firewall reload")
		end

		return {
			success = true,
			changed_network = changed_network,
			changed_firewall = changed_firewall,
			message = (changed_network or changed_firewall) and "Tailscale firewall/interface configuration applied." or "Tailscale firewall/interface already configured."
		}
	end)

	if not ok then
		return { error = "Exception in setup_firewall: " .. tostring(err) }
	end
	return err
end

return { tailscale = methods }