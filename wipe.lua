-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- wipe.lua
-- Emergency full filesystem wipe utility.
-- Deletes everything on this computer except
-- the protected rom directory. Does not reboot
-- automatically. After wiping, paste the
-- bootstrap one-liner to reinitialize.
-- Use only when the computer is in a state
-- that cannot be repaired by normal recovery.
--
-- Branches : interactive_role_selector
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] WIPE                ln. 20
-- [2] ENTRY POINT         ln. 40
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- ===========================================================================
-- [1] WIPE
-- ===========================================================================

local PROTECTED_DIRECTORIES = { rom = true }

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

-- ===========================================================================
-- [2] ENTRY POINT
-- ===========================================================================

print("=========================================")
print("         EMERGENCY WIPE UTILITY          ")
print("=========================================")
print("")
print("Deletes ALL files except rom.")
print("")
io.write("Type WIPE to confirm, anything else cancels: ")
local input = io.read()

if input ~= "WIPE" then
    print("")
    print("Wipe cancelled. No files deleted.")
    return
end

print("")
print("Wiping filesystem...")
print("")
local deleted_count = wipe_filesystem()
print("")
print("Wipe complete. " .. deleted_count .. " item(s) deleted.")
print("")
print("Paste bootstrap one-liner to reinitialize:")
print("")
print('local r=http.get("https://raw.githubusercontent.com/')
print('ZacharyTPerry-lang/cc-repo/main/bootstrap.lua")')
print('local f=fs.open("bootstrap.lua","w")')
print('f.write(r.readAll()) f.close() r.close()')
print('shell.run("bootstrap.lua")')
print("")
