local socket=require("socket")
local lfs=require("lfs")

function tpairs(tbl)
	local s={}
	local c=1
	for k,v in pairs(tbl) do
		s[c]=k
		c=c+1
	end
	c=0
	return function()
		c=c+1
		return s[c],tbl[s[c]]
	end
end

fs={
	exists=function(file)
		return lfs.attributes(file)~=nil
	end,
	isDir=function(file)
		local dat=lfs.attributes(file)
		if not dat then
			return nil
		end
		return dat.mode=="directory"
	end,
	isFile=function(file)
		local dat=lfs.attributes(file)
		if not dat then
			return nil
		end
		return dat.mode=="file"
	end,
	split=function(file)
		local t={}
		for dir in file:gmatch("[^/]+") do
			t[#t+1]=dir
		end
		return t
	end,
	combine=function(filea,fileb)
		local o={}
		for k,v in pairs(fs.split(filea)) do
			table.insert(o,v)
		end
		for k,v in pairs(fs.split(fileb)) do
			table.insert(o,v)
		end
		return filea:match("^/?")..table.concat(o,"/")..fileb:match("/?$")
	end,
	resolve=function(file)
		local b,e=file:match("^(/?).-(/?)$")
		local t=fs.split(file)
		local s=0
		for l1=#t,1,-1 do
			local c=t[l1]
			if c=="." then
				table.remove(t,l1)
			elseif c==".." then
				table.remove(t,l1)
				s=s+1
			elseif s>0 then
				table.remove(t,l1)
				s=s-1
			end
		end
		return b..table.concat(t,"/")..e
	end,
	list=function(dir)
		dir=dir or ""
		local o={}
		for fn in lfs.dir(dir) do
			if fn~="." and fn~=".." then
				table.insert(o,fn)
			end
		end
		return o
	end,
}

dofile("hook.lua")
dofile("async.lua")

hook.new("page_hello",function()
	return {
		data="Hello, World!",
	}
end)

local sv=assert(socket.bind("*",8080))
sv:settimeout(0)
hook.newsocket(sv)
local cli={}
local function close(cl)
	cl:close()
	cli[cl]=nil
	hook.remsocket(cl)
end

function urlencode(txt)
	return txt:gsub("\r?\n","\r\n"):gsub("[^%w ]",function(t) return string.format("%%%02X",t:byte()) end):gsub(" ","+")
end

function urldecode(txt)
	return txt:gsub("+"," "):gsub("%%(%x%x)",function(t) return string.char(tonumber("0x"..t)) end)
end

function htmlencode(txt)
	return txt:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub("\"","&quot;"):gsub("'","&apos;"):gsub("\r?\n","<br>")
end

function parseurl(url)
	local out={}
	for var,dat in url:gmatch("([^&]+)=([^&]+)") do
		out[urldecode(var)]=urldecode(dat)
	end
	return out
end

local ctype={
	["html"]="text/html",
	["css"]="text/css",
	["png"]="image/png",
	["txt"]="text/plain",
}

local function req(cl)
	local cldat=cli[cl]
	local url=cldat.url
	cldat.urldata=parseurl(url:match(".-%?(.+)") or "")
	if cldat.post then
		cldat.postdata=parseurl(cldat.post)
	end
	url=fs.resolve(url:match("(.-)%?.+") or url)
	local res=hook.queue("page_"..url,cldat)
	url=fs.split(url)
	local file=url[#url] or ""
	url=table.concat(url,"/")
	local bse=fs.combine("www",url):gsub("/$","")
	if not res then
		res={}
		if not fs.exists(bse) then
			res.data="<center><h1>404 Not found.</h1></center>"
			res.code="404 Not found"
		else
			if fs.isDir(bse) then
				local gt=false
				for k,v in pairs(fs.list(bse)) do
					if v:match("^index%.") then
						url=fs.combine(url,v)
						gt=true
						break
					end
				end
				if not gt then
					local o=""
					for k,v in pairs(fs.list(bse)) do
						o=o.."<a href=\""..fs.combine(url,v):gsub("^/","").."\">"..htmlencode(v).."</a><br>"
					end
					res.data=o
				end
			end
			if not res.data then
				local bse=fs.combine("www",url):gsub("/$","")
				local ext=url:match(".+%.(.-)$") or ""
				res.type=ctype[ext]
				local fl=assert(io.open(bse,"rb"))
				if ext=="lua" then
					local func,err=loadstring(fl:read("*a"),"="..url)
					if not func then
						res.data=err:gsub("\n","<br>")
						res.code="500 Internal Server Error"
						res.type="text/raw"
					else
						local o=""
						local e=setmetatable({
							print=function(...)
								o=o..table.concat({...}," ").."\r\n"
							end,
							write=function(...)
								o=o..table.concat({...}," ")
							end,
							postdata=cldat.postdata,
							urldata=cldat.urldata,
							cl=cldat,
						},{__index=_G})
						local err,out=xpcall(setfenv(func,e),debug.traceback)
						if not err then
							res.data=out
							res.code="500 Internal Server Error"
							res.type="text/raw"
						else
							res.data=o
							res.code=e.code or "200 Found"
							res.type="text/html"
						end
					end
				else
					res.data=fl:read("*a")
					fl:close()
				end
			end
		end
	end
	res.headers=res.headers or {}
	res.headers["Content-Length"]=#res.data
	res.code=res.code or "200 Found"
	res.headers["Content-Type"]=res.headers["Content-Type"] or res.type or "text/html"
	res.headers["Connection"]="close"
	local o="HTTP/1.1 "..res.code
	for k,v in pairs(res.headers) do
		o=o.."\r\n"..k..": "..v
	end
	cl:send(o.."\r\n\r\n")
	async.new(function()
		async.socket(cl).send(res.data)
		close(cl)
	end)
end

hook.new("select",function()
	local cl=sv:accept()
	while cl do
		hook.newsocket(cl)
		cl:settimeout(0)
		cli[cl]={headers={},ip=cl:getpeername()}
		cl=sv:accept()
	end
	for cl,cldat in pairs(cli) do
		local s,e=cl:receive(0)
		if not s and e=="closed" then
			close(cl)
		else
			local s,e=cl:receive(tonumber(cldat.post and cldat.headers["Content-Length"]))
			if s then
				if cldat.post then
					cldat.post=s
					req(cl)
				elseif s=="" then
					if cldat.method=="POST" then
						cldat.post=""
					elseif cldat.method=="GET" then
						req(cl)
					else
						close(cl)
					end
				else
					if not s:match(":") then
						cldat.method=s:match("^(%S+)")
						cldat.url=(s:match("^%S+ (%S+)") or ""):gsub("^/","")
					else
						cldat.headers[s:match("^(.-):")]=s:match("^.-: (.+)")
					end
				end
			end
		end
	end
end)

while true do
	hook.queue("select",socket.select(hook.sel,hook.rsel,math.min(10,hook.interval or 10)))
end