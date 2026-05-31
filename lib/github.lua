-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- lib/github.lua
-- GitHub Contents API helpers for reading
-- and writing files on cc-repo. Used by the
-- reactor builder to claim slots and update
-- job_meta.json with build progress.
-- Requires a fine-grained token with
-- Contents: Read and Write on cc-repo.
--
-- await_http_response requeues unrecognised
-- events so parallel.waitForAny callers
-- do not lose key/char events while an HTTP
-- request is in flight.
--
-- Branches : reactor-1, reactor-2,
--            reactor-3, reactor-4,
--            reactor-5, reactor-6,
--            reactor-7, reactor-8,
--            reactor-9, reactor-10
-- Depends  : lib/base64
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] CONFIGURATION       ln. 30
-- [2] HTTP HELPERS        ln. 45
-- [3] CONTENTS API        ln. 105
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- =========================================
-- [1] CONFIGURATION
-- =========================================

local base64 = require("lib.base64")

local REPO_OWNER    = "ZacharyTPerry-lang"
local REPO_NAME     = "cc-repo"
local API_ROOT      = "https://api.github.com"
local CONTENTS_PATH =
    "/repos/"
    .. REPO_OWNER .. "/" .. REPO_NAME
    .. "/contents/"
local HTTP_TIMEOUT  = 30

-- =========================================
-- [2] HTTP HELPERS
-- =========================================

-- build_auth_headers
-- Returns headers required by every GitHub
-- API call, including the personal access
-- token for authenticated write access.
local function build_auth_headers(token)
    return {
        ["Authorization"]  =
            "token " .. token,
        ["Accept"]         =
            "application/vnd.github.v3+json",
        ["User-Agent"]     = "CC-Turtle/1.0",
        ["Content-Type"]   = "application/json",
    }
end

-- await_http_response
-- Waits for http_success or http_failure
-- matching the given URL, with a bounded
-- timeout. Returns body, success, http_code.
--
-- Unrecognised events (key, char, redraw,
-- etc.) are requeued via os.queueEvent so
-- that parallel.waitForAny coroutines such
-- as io.read() are not starved of input
-- events while an HTTP request is in flight.
local function await_http_response(url)
    local timer_id =
        os.startTimer(HTTP_TIMEOUT)
    while true do
        local event, p1, p2, p3 =
            os.pullEventRaw()
        if event == "http_success"
                and p1 == url then
            local code = p2.getResponseCode()
            local body = p2.readAll()
            p2.close()
            os.cancelTimer(timer_id)
            return body, true, code
        elseif event == "http_failure"
                and p1 == url then
            os.cancelTimer(timer_id)
            return tostring(p2), false, 0
        elseif event == "timer"
                and p1 == timer_id then
            return "http timeout", false, 0
        elseif event == "terminate" then
            -- Propagate terminate so pcall
            -- callers can handle Ctrl+T.
            os.cancelTimer(timer_id)
            error("Terminated")
        else
            -- Requeue so other coroutines
            -- (io.read, movement, etc.)
            -- are not starved of events.
            os.queueEvent(event, p1, p2, p3)
        end
    end
end

-- =========================================
-- [3] CONTENTS API
-- =========================================

-- fetch_file_with_sha
-- Fetches file_path from branch via the
-- GitHub Contents API (authenticated).
-- Returns data_table, sha, error_string.
-- sha is required for subsequent updates.
-- The data table contains the raw API
-- response; content is base64 encoded.
local function fetch_file_with_sha(
        file_path, branch, token)
    local url = API_ROOT .. CONTENTS_PATH
        .. file_path
        .. "?ref=" .. branch
    local headers = build_auth_headers(token)
    http.request({
        url     = url,
        headers = headers,
        method  = "GET",
    })
    local body, success, _ =
        await_http_response(url)
    if not success then
        return nil, nil, body
    end
    local data =
        textutils.unserialiseJSON(body)
    if not data or not data.sha then
        return nil, nil, "parse failed"
    end
    return data, data.sha, nil
end

-- update_file
-- Writes new_content_string to file_path
-- on branch. current_sha must match the
-- latest SHA or GitHub returns 409.
-- Returns new_sha, error_string, http_code.
--
-- Callers use http_code to distinguish:
--   200 = success
--   409 = SHA conflict (race condition)
--   0   = network/timeout error
local function update_file(
        file_path,
        branch,
        new_content_string,
        current_sha,
        token,
        commit_message)
    local url = API_ROOT .. CONTENTS_PATH
        .. file_path
    local headers = build_auth_headers(token)
    local encoded =
        base64.encode(new_content_string)
    local body = textutils.serialiseJSON({
        message = commit_message,
        content = encoded,
        sha     = current_sha,
        branch  = branch,
    })
    http.request({
        url     = url,
        body    = body,
        headers = headers,
        method  = "PUT",
    })
    local response, success, http_code =
        await_http_response(url)
    if not success then
        return nil, response, http_code
    end
    local data =
        textutils.unserialiseJSON(response)
    if not data
            or not data.content
            or not data.content.sha then
        return nil, "parse failed", http_code
    end
    return data.content.sha, nil, http_code
end

return {
    fetch_file_with_sha = fetch_file_with_sha,
    update_file         = update_file,
}
