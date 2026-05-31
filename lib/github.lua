-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- lib/github.lua
-- GitHub Contents API helpers for reading
-- and writing files on cc-repo. Used by the
-- reactor builder to update job_meta.json
-- with build progress and final status.
-- Requires a fine-grained token with
-- Contents: Read and Write on cc-repo.
--
-- await_http_response uses a bounded timer
-- so no call can block indefinitely.
--
-- Branches : reactor-1, reactor-2,
--            reactor-3, reactor-4,
--            reactor-5, reactor-6,
--            reactor-7, reactor-8,
--            reactor-9, reactor-10
-- Depends  : lib/base64
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] CONFIGURATION       ln. 28
-- [2] HTTP HELPERS        ln. 42
-- [3] CONTENTS API        ln. 90
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- =========================================
-- [1] CONFIGURATION
-- =========================================

local base64 = require("lib.base64")

local REPO_OWNER   = "ZacharyTPerry-lang"
local REPO_NAME    = "cc-repo"
local API_ROOT     = "https://api.github.com"
local CONTENTS_URL = API_ROOT
    .. "/repos/"
    .. REPO_OWNER .. "/" .. REPO_NAME
    .. "/contents/"
local HTTP_TIMEOUT = 30

-- =========================================
-- [2] HTTP HELPERS
-- =========================================

-- build_auth_headers
-- Returns the header table required by
-- every GitHub API call. Includes the
-- personal access token for write access.
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
-- Waits for an http_success or http_failure
-- event matching the given URL. A timer
-- guarantees termination within
-- HTTP_TIMEOUT seconds regardless of
-- network conditions. Returns body, success.
local function await_http_response(url)
    local timer_id =
        os.startTimer(HTTP_TIMEOUT)
    while true do
        local event, param1, param2 =
            os.pullEvent()
        if event == "http_success"
                and param1 == url then
            local body = param2.readAll()
            param2.close()
            os.cancelTimer(timer_id)
            return body, true
        elseif event == "http_failure"
                and param1 == url then
            os.cancelTimer(timer_id)
            return tostring(param2), false
        elseif event == "timer"
                and param1 == timer_id then
            return "http timeout", false
        end
    end
end

-- =========================================
-- [3] CONTENTS API
-- =========================================

-- fetch_file_with_sha
-- Fetches file_path from the given branch
-- via the GitHub Contents API (authenticated
-- so rate limit is 5000/hour).
-- Returns parsed_data, sha, error_string.
-- The sha field is required for update_file.
local function fetch_file_with_sha(
        file_path, branch, token)
    local url = CONTENTS_URL
        .. file_path
        .. "?ref=" .. branch
    local headers = build_auth_headers(token)

    http.request({
        url     = url,
        headers = headers,
        method  = "GET",
    })

    local body, success =
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
-- on branch via a GitHub Contents API PUT.
-- current_sha must be the sha returned by
-- the previous fetch or update; GitHub
-- rejects updates without the current sha.
-- Returns new_sha, error_string.
-- new_sha must be used for the next update.
local function update_file(
        file_path,
        branch,
        new_content_string,
        current_sha,
        token,
        commit_message)
    local url = CONTENTS_URL .. file_path
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

    local response, success =
        await_http_response(url)
    if not success then
        return nil, response
    end

    local data =
        textutils.unserialiseJSON(response)
    if not data
            or not data.content
            or not data.content.sha then
        return nil, "response parse failed"
    end

    return data.content.sha, nil
end

return {
    fetch_file_with_sha = fetch_file_with_sha,
    update_file         = update_file,
}
