local urlparse = require("socket.url")
local http = require("socket.http")
local cjson = require("cjson")
-- local utf8 = require("utf8")
-- local utf8 = require("lua-utf8")
local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))

-- local item_dir = "./items/"
-- local warc_file_base = "test"
-- local concurrency = 5

local item_type = nil
local item_name = nil
local item_value = nil
local ids = {}

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_items = {}
local bad_items = {}

local retry_url = false

local cooldown = 0

local item_patterns = {
    ["^https?://[^/]*zapytaj%.onet%.pl/Category/(%d+,%d+/%d,%d+,[^/]+)%.html?"]="question",
    ["^https?://[^/]*zapytaj%.onet%.pl/Category/(%d+,%d+/%d,%d+,[^/]+),comments,%d+%.html"]="question",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/user_(%d+)%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/page,question,(%d+),%d+%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/page,quiz,(%d+),%d+%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/page,answer,(%d+),%d+%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/page,guide,(%d+),%d+%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/5,best,(%d+),%d+%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/Profile/(%d+)/"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/profil/(%d+)/"]="user",
    ["^https?://r%.adres%.pl/(%d+)%.html"]="user",
    ["^https?://[^/]*zapytaj%.onet%.pl/klub/([0-9a-zA-Z_%-]+)[/%?]?"]="club",
    ["^https?://[^/]*zapytaj%.onet%.pl/image/generate%.html%?url=(.+)"]="image-redirect",
    ["^(https?://[^/]*ocdn%.eu/zapytaj.+)"]="image",
    ["^(https?://[^/]*ocdn%.eu/_m.+)"]="image",
  }

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  local f = assert(io.open(file, "rb"))
  local data = f:read("*all")
  f:close()
  return data
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
--print("discovered", item)
    target[item] = true
    return true
  end
  return false
end

query_param = function(url, name)
  local query = string.match(url, "%?(.+)$")
  if not query then
    return nil
  end
  for key, value in string.gmatch(query, "([^&=]+)=?([^&]*)") do
    if key == name then
      return urlparse.unescape(value)
    end
  end
  return nil
end

find_item = function(url)
  url = urlparse.unescape(url)
  for pattern, type_ in pairs(item_patterns) do
    local value = string.match(url, pattern)
    if value then
      return {
        ["type"]=type_,
        ["value"]=value
      }
    end
  end
end

set_item = function(url)
  local found = find_item(url)
  if found then
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    -- if found["type"] == "image-redirect" then
    --   io.stdout:write("found image-redirect")
    -- end
    if new_item_name ~= item_name then
      item_value = new_item_value
      item_type = new_item_type
      ids = {}
      ids[item_value] = true
      abortgrab = false
      tries = 0
      retry_url = false
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, body_data)
  if not string.match(url, "^https?://") then
    return false
  end

  if string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/img/_logoBorder_.gif%?")
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/report%-notice/")
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/klub/[^/]+/zapytaj%.html") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/klub/utworz%.html") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/klub/[^/]+/quiz/create%.html") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/klub/[^/]+/zabawy-quizowe/create%.html") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/Profile/Friends/") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/Profile/Clubs/") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/Category/[^/]+/AddVote,") 
    or string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/Category/[^/]+/AddAnswer,") 
    then
    -- io.stdout:write("skipped based on ignores " .. url ..  "\n")
    -- io.stdout:flush()
    return false
  end

  if not string.match(url, "^https?://[^/]*zapytaj%.onet%.pl/")
    and not string.match(url, "^https?://[^/]*r%.adres%.pl/")
    and not string.match(url, "^https?://[^/]*ocdn%.eu/") then
    return false
  end

  local found = find_item(url)
  if found then
    local found_item_name = found["type"] .. ":" .. found["value"]
    -- these urls are found in the html redundant - not sure if we should capture these
    if found["type"] == "question" then
      -- question_url?page=0 is the same as question_url without page param so we should skip
      if string.match(url, "%.html%?page=0") then
        io.stdout:write("found page 0\n")
        io.stdout:flush()
        return false
      end

      -- question_url,comments,0.html is the same as question_url.html
      if string.match(url, ",comments,0,%.html") then
        io.stdout:write("found comments page 0\n")
        io.stdout:flush()
        return false
      end

      -- question_url,comments,%d.html?show_results=true will not show results
      if string.match(url, ",comments,%d+,%.html%?show_results=true") then
        io.stdout:write("found show_results with comments\n")
        io.stdout:flush()
        return false
      end
    end

    -- prezenty.html?page=1 is the same as prezenty.html
    if found["type"] == "user" then
      if string.match(url, "/profil/%d+/prezenty%.html%?page=1") then
        io.stdout:write("found profile gifts page 1\n")
        io.stdout:flush()
        return false
      end
    end

    if found_item_name ~= item_name then
      discover_item(discovered_items, found_item_name)
      return false
    end
    return true
  end

  -- io.stdout:write("not found " .. url .. "\n")
  -- io.stdout:flush()
  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil
  local body_data = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    local post_body = nil
    local post_url = nil
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      table.insert(urls, {
        url=url_,
        headers=headers
      })
      addedtolist[url_] = true
      addedtolist[url] = true
    -- else
    --   if not allowed(url_, origurl) then
    --     io.stdout:write("Skipped [not allowed] " .. url .. "\n")
    --     io.stdout:flush()
    --   end
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function set_new_params(newurl, data)
    for param, value in pairs(data) do
      if value == nil then
        value = ""
      elseif type(value) == "string" then
        value = "=" .. value
      end
      if string.match(newurl, "[%?&]" .. param .. "[=&]") then
        newurl = string.gsub(newurl, "([%?&]" .. param .. ")=?[^%?&;]*", "%1" .. value)
      else
        if string.match(newurl, "%?") then
          newurl = newurl .. "&"
        else
          newurl = newurl .. "?"
        end
        newurl = newurl .. param .. value
      end
    end
    return newurl
  end

  local function increment_param(newurl, param, default, step)
    local value = string.match(newurl, "[%?&]" .. param .. "=([0-9]+)")
    if value then
      value = tonumber(value)
      value = value + step
      return set_new_params(newurl, {[param]=tostring(value)})
    else
      return set_new_params(newurl, {[param]=tostring(default)})
    end
  end

  local function flatten_json(json)
    local result = ""
    for k, v in pairs(json) do
      result = result .. " " .. k
      local type_v = type(v)
      if type_v == "string" then
        v = string.gsub(v, "\\", "")
        result = result .. " " .. v .. ' "' .. v .. '"'
      elseif type_v == "table" then
        result = result .. " " .. flatten_json(v)
      end
    end
    return result
  end
  

  if string.match(url, "^https?://zapytaj%.onet%.pl/image/generate%.html%?url=")
    and item_type == "image-redirect" then
    -- these urls often contain the image in its original quality stored on ocdn servers
    -- ive only seen these urls present with "&image=large", still leaving second option as fallback
    local orig_url = string.match(url, "url=(.+)&image=large") or string.match(url, "url=(.+)$")
    io.stdout:write("found image-redirect")
    io.stdout:flush()
    if orig_url then
      check(orig_url)
    end
  end

  if allowed(url)
    and status_code < 300
    and ( 
      item_type ~= "image-redirect"
      or item_type ~= "image" )
    then
    html = read_file(file)

    -- auto check other user pages - blocked users dont have some urls listed in the html
    if item_type == "user" then
      check("https://zapytaj.onet.pl/Profile/page,question," .. item_value .. ",0.html")
      check("https://zapytaj.onet.pl/Profile/page,quiz," .. item_value .. ",0.html")
      check("https://zapytaj.onet.pl/Profile/page,answer," .. item_value .. ",0.html")
      check("https://zapytaj.onet.pl/Profile/5,best," .. item_value .. ",0.html")
      check("https://zapytaj.onet.pl/Profile/page,guide," .. item_value .. ",0.html")
      check("https://zapytaj.onet.pl/Profile/" .. item_value .. "/Comments/0.html")
      check("https://zapytaj.onet.pl/Profile/" .. item_value .. "/Comments/By/User/0.html")
      check("https://zapytaj.onet.pl/profil/" .. item_value .. "/prezenty.html")
      -- if user is blocked badges are never visible
      if not string.match(html, '<div class="user%-desc%-details">%s*<h1>blocked</h1>') then
        check("https://zapytaj.onet.pl/profil/" .. item_value .. "/odznaki.html")
      else
        io.stdout:write("User is blocked!\n")
        io.stdout:flush()
      end
    end

    for newurl in string.gmatch(string.gsub(html, "&[qQ][uU][oO][tT];", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    html = string.gsub(html, "&gt;", ">")
    html = string.gsub(html, "&lt;", "<")
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  if http_stat["len"] == 0
    and status_code < 300 then
    retry_url = true
    return false
  end
  if status_code ~= 200
    and status_code ~= 302 then
    retry_url = true
    return false
  end
  if status_code == 302 then
    if not http_stat["newloc"] then
      retry_url = true
      return false
    end
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  -- 504 errors often mean that some kind of bot check/throttling was kicked off. 
  -- waiting between 5 to 30 secs should resolve this automatically tho
  if status_code == 504 then
    tries = tries + 1
    local maxtries = 6
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    cooldown = tries * 5
    io.stdout:write("Server returned 504! Slowing down for " .. cooldown .. " seconds")
    io.stdout:flush()
    os.execute("sleep " .. cooldown)
    return wget.actions.CONTINUE
  end

  -- 429 error = ratelimited. todo: check how long we should wait before being unbanned!
  -- set sleep time to 5 mins now... is that ok? or should we kill the crawl instead
  if status_code == 429 then
    tries = tries + 1
    local maxtries = 6
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    cooldown = 300
    io.stdout:write("Server returned 429 - rate limited! Slowing down for " .. cooldown .. " seconds")
    io.stdout:flush()
    os.execute("sleep " .. cooldown)
    return wget.actions.CONTINUE
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 6
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 or status_code == 206 then
      if not seen_200[url["url"]] then
        seen_200[url["url"]] = 0
      end
      seen_200[url["url"]] = seen_200[url["url"]] + 1
    end
    downloaded[url["url"]] = true
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  -- dummy submit_backfeed func
  local function submit_backfeed(items, key)
    io.stdout:write("Doin backfeed and stuff\n")
    return nil
  end
  -- local function submit_backfeed(items, key)
  --   local tries = 0
  --   local maxtries = 5
  --   while tries < maxtries do
  --     if killgrab then
  --       return false
  --     end
  --     local body, code, headers, status = http.request(
  --       "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
  --       items .. "\0"
  --     )
  --     if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
  --       io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
  --       io.stdout:flush()
  --       return nil
  --     end
  --     io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
  --     io.stdout:flush()
  --     os.execute("sleep " .. math.floor(math.pow(2, tries)))
  --     tries = tries + 1
  --     io.stdout:write("Skipping backfeed")
  --     return nil
  --   end
  --   kill_grab()
  --   error()
  -- end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["placeholder"] = discovered_items
  }) do
    print("queuing for", string.match(key, "^(.+)%-") or key)
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end
