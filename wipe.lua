-- wipe.lua
-- Emergency full wipe of this computer's filesystem.
-- Deletes everything except the protected rom directory.
-- Does NOT reboot automatically -- that is the developer's decision.
-- After wiping, paste the bootstrap one-liner to reinitialize.
--
-- Run with: shell.run("wipe.lua")
-- Or fetch directly:
--   local r=http.get("https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/interactive_role_selector/wipe.lua")
--   local f=fs.open("wipe.lua","w") f.write(r.readAll()) f.close() r.close()
--   shell.run("wipe.lua")

local PROTECTED_DIRECTORIES = { rom = true }

local function confirm_wipe()
    print("=========================================")
    print("           EMERGENCY WIPE UTILITY        ")
    print("=========================================")
    print("")
    print("This will delete ALL files on this computer")
    print("except the protected rom directory.")
    print("")
    print("After wiping, paste the bootstrap one-liner")
    print("to reinitialize.")
    print("")
    io.write("Type WIPE to confirm, or anything else to cancel: ")
    local input = io.read()
    return input == "WIPE"
end

local function wipe_filesystem()
    local deleted_count = 0
    for _, entry in ipairs(fs.list("/")) do
        if not PROTECTED_DIRECTORIES[entry] then
            fs.delete(entry)
            print("Deleted: " .. entry)
            deleted_count = deleted_count + 1
        end
    end
    return deleted_count
end

if not confirm_wipe() then
    print("")
    print("Wipe cancelled. No files were deleted.")
    return
end

print("")
print("Wiping filesystem...")
print("")
local deleted_count = wipe_filesystem()
print("")
print("Wipe complete. " .. deleted_count .. " item(s) deleted.")
print("")
print("Paste the bootstrap one-liner to reinitialize:")
print("")
print('local r=http.get("https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/bootstrap.lua")')
print('local f=fs.open("bootstrap.lua","w") f.write(r.readAll()) f.close() r.close()')
print('shell.run("bootstrap.lua")')
print("")
