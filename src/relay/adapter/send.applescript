on run argv
    set operation to item 1 of argv
    set destination to item 2 of argv
    set bodyText to item 3 of argv
    set dispatchStarted to false
    try
        tell application "Messages"
            set candidates to every account whose service type is iMessage and enabled is true
            if (count of candidates) is not 1 then return "unsupported_account"
            set imAccount to item 1 of candidates
            if operation is "check" then return "ready"
            if operation is "direct" then
                set recipient to participant destination of imAccount
                set dispatchStarted to true
                send bodyText to recipient
            else if operation is "chat" then
                set destinationChat to chat id destination
                if service type of account of destinationChat is not iMessage then return "unsupported_target"
                if id of account of destinationChat is not id of imAccount then return "unsupported_account"
                set dispatchStarted to true
                send bodyText to destinationChat
            else
                return "unsupported_target"
            end if
            return "invoked"
        end tell
    on error errorText number errorNumber
        if dispatchStarted then return "unknown"
        if errorNumber is -1743 then return "permission_required"
        if errorNumber is -1728 and operation is "chat" then return "unsupported_target"
        return "adapter_unavailable"
    end try
end run
