-- Memory-Optimized ComputerCraft Video Player
-- Decodes frames on-the-fly to minimize memory usage
-- Uses precise timing without a scheduler
-- Starts playback on redstone signal

-- Forward declare functions
local getTimeMs
local loadAndDecodeFrame
local displayFrame
local downloadVideo
local compensatedSleep
local parseVideoHeader
local waitForRedstoneSignal

-- Get peripherals
local modem = peripheral.find("modem")
local monitor = peripheral.find("monitor")

if not monitor then error("No monitor found!", 0) end

-- Setup monitor
monitor.clear()
monitor.setTextColor(colors.white)
monitor.setBackgroundColor(colors.black)
monitor.setCursorPos(1, 1)
monitor.write("Waiting for redstone signal...")

-- Open rednet if we have a modem
if modem then
    local modemName = peripheral.getName(modem)
    rednet.open(modemName)
    print("[INFO] Rednet opened on: " .. modemName)
else
    print("[INFO] No modem found, running in standalone mode")
end

-- Configuration
local FPS = 10
local FRAME_TIME_MS = 1000 / FPS -- 100ms per frame at 10 FPS
local baseURL = "https://raw.githubusercontent.com/robertjojo123/SIL/refs/heads/main/video_part_"

-- Display calculations - now using full monitor
local monW, monH = monitor.getSize()
local startX = 1
local startY = 1

-- State variables
local currentPart = 1
local isPlaying = false
local videoFile = nil
local totalFrames = 0
local isCompressed = false
local decompressedData = nil
local decompressPosition = 1
local frameLineCount = 0

-- Add zlib decompression if available (via cc-tweaked or similar)
local hasZlib = false
local zlib = nil
local base64 = nil

-- Try to load compression libraries
pcall(function()
    -- Try to load zlib if available
    zlib = require("zlib")
    base64 = require("base64")
    hasZlib = true
    print("[INFO] Compression libraries loaded successfully")
end)

-- If compression libraries aren't available, implement basic alternatives
if not hasZlib then
    print("[WARN] Compression libraries not found, using fallback method")
    -- This is a very simplified implementation that won't actually decompress
    -- It will only work with uncompressed files
    base64 = {}
    base64.decode = function(str)
        return str
    end
    
    zlib = {}
    zlib.decompress = function(data)
        return data
    end
end

-- Get time in milliseconds
getTimeMs = function()
    return math.floor(os.epoch("utc"))
end

-- Precise sleep function that compensates for processing time
compensatedSleep = function(targetTimeMs)
    local currentTimeMs = getTimeMs()
    local sleepTimeMs = targetTimeMs - currentTimeMs
    
    if sleepTimeMs > 0 then
        os.sleep(sleepTimeMs / 1000) -- Convert to seconds
    end
end

-- Path handling for full video files
local function getVideoPath(part)
    return "/video_part_" .. tostring(part) .. ".bvf"
end

-- Download video part
downloadVideo = function(part)
    local path = getVideoPath(part)
    local url = baseURL .. tostring(part) .. ".bvf"
    print("[DOWNLOAD] Starting download of part " .. part)
    
    local startTime = getTimeMs()
    
    -- Try to download the file
    local success = false
    local attempts = 0
    local maxAttempts = 3
    
    while not success and attempts < maxAttempts do
        attempts = attempts + 1
        print("[DOWNLOAD] Attempt " .. attempts .. "/" .. maxAttempts)
        
        local response, err
        pcall(function()
            response = http.get(url, nil, true)
        end)
        
        if response then
            local file = fs.open(path, "wb")
            if file then
                file.write(response.readAll())
                file.close()
                response.close()
                success = true
                print("[DOWNLOAD] Successfully downloaded part " .. part)
            else
                if response then response.close() end
                print("[ERROR] Could not write to file: " .. path)
            end
        else
            print("[ERROR] Download failed: " .. (err or "unknown error"))
        end
        
        if not success then
            print("[RETRY] Waiting before retry...")
            os.sleep(1)
        end
    end
    
    local endTime = getTimeMs()
    local downloadTime = endTime - startTime
    print("[DOWNLOAD] Part " .. part .. " took " .. downloadTime .. "ms to download")
    
    return success
end

-- Parse the video header to get information about the video
parseVideoHeader = function(file)
    -- Read resolution and fps
    local headerLine = file.readLine()
    if not headerLine then
        return false, "Failed to read header"
    end
    
    -- Parse width, height, fps
    local width, height, fps = headerLine:match("(%d+) (%d+) (%d+)")
    width, height, fps = tonumber(width), tonumber(height), tonumber(fps)
    
    if not width or not height or not fps then
        return false, "Invalid header format"
    end
    
    -- Read number of frames
    local framesLine = file.readLine()
    if not framesLine then
        return false, "Failed to read frame count"
    end
    
    local frames = tonumber(framesLine)
    if not frames then
        return false, "Invalid frame count"
    end
    
    -- Check if compressed
    local compressionLine = file.readLine()
    local isCompressed = compressionLine == "COMPRESSED"
    
    return true, {
        width = width,
        height = height,
        fps = fps,
        frames = frames,
        isCompressed = isCompressed
    }
end

-- Open the video file and read the header
local function openVideoFile(path)
    if not fs.exists(path) then
        print("[ERROR] Video file not found: " .. path)
        return false
    end
    
    print("[LOAD] Opening video from: " .. path)
    local file = fs.open(path, "r")
    if not file then return false end
    
    -- Parse header
    local success, result = parseVideoHeader(file)
    if not success then
        file.close()
        print("[ERROR] " .. result)
        return false
    end
    
    -- Store video information
    totalFrames = result.frames
    isCompressed = result.isCompressed
    
    -- Use the FPS from the video if available
    if result.fps and result.fps > 0 then
        FPS = result.fps
        FRAME_TIME_MS = 1000 / FPS
        print("[INFO] Using video FPS: " .. FPS .. " (" .. FRAME_TIME_MS .. "ms per frame)")
    end
    
    -- Handle compression
    if isCompressed then
        print("[INFO] Video is compressed, preparing decompressor")
        if not hasZlib then
            print("[ERROR] Compressed video but zlib not available")
            file.close()
            return false
        end
        
        -- Read the compressed data
        local compressedData = file.readAll()
        file.close()
        
        -- Decode base64
        local decodedData = base64.decode(compressedData)
        
        -- Decompress
        decompressedData = zlib.decompress(decodedData)
        decompressPosition = 1
        
        -- Read first line to determine number of lines per frame
        local lineEndPos = decompressedData:find("\n", decompressPosition)
        if lineEndPos then
            local lineStr = decompressedData:sub(decompressPosition, lineEndPos - 1)
            frameLineCount = tonumber(lineStr) or 0
            decompressPosition = lineEndPos + 1
        else
            print("[ERROR] Failed to parse decompressed data")
            decompressedData = nil
            return false
        end
        
        print("[INFO] Decompressed data ready, " .. frameLineCount .. " lines per frame")
        return true
    else
        -- For uncompressed files, keep the file handle open
        videoFile = file
        return true
    end
end

-- Read the next line from either the file or the decompressed data
local function readNextLine()
    if isCompressed then
        if not decompressedData or decompressPosition > #decompressedData then
            return nil
        end
        
        local lineEndPos = decompressedData:find("\n", decompressPosition)
        if not lineEndPos then
            -- Last line might not have a newline
            lineEndPos = #decompressedData + 1
        end
        
        local line = decompressedData:sub(decompressPosition, lineEndPos - 1)
        decompressPosition = lineEndPos + 1
        return line
    else
        if not videoFile then
            return nil
        end
        
        return videoFile.readLine()
    end
end

-- Load and decode a single frame
loadAndDecodeFrame = function(frameIndex)
    if isCompressed then
        -- For compressed data, we need to skip to the correct frame position
        if frameIndex > 1 and decompressPosition == 1 then
            -- Need to skip frames if we're starting from the beginning
            for i = 1, frameIndex - 1 do
                -- Each frame has a header line + 3 sets of frameLineCount lines
                local totalLinesToSkip = 1 + (frameLineCount * 3)
                for j = 1, totalLinesToSkip do
                    if not readNextLine() then
                        print("[ERROR] Reached end of data while skipping to frame " .. frameIndex)
                        return nil
                    end
                end
            end
        end
    end
    
    -- Read number of lines for this frame (only in compressed mode)
    local numLines = frameLineCount
    if isCompressed then
        local lineSizeStr = readNextLine()
        if not lineSizeStr then
            print("[ERROR] Failed to read line count for frame " .. frameIndex)
            return nil
        end
        numLines = tonumber(lineSizeStr) or frameLineCount
    end
    
    -- Read text lines
    local text_lines = {}
    for i = 1, numLines do
        local line = readNextLine()
        if not line then
            print("[ERROR] Unexpected end of file reading frame " .. frameIndex)
            return nil
        end
        text_lines[i] = line
    end
    
    -- Read foreground color lines
    local fg_lines = {}
    for i = 1, numLines do
        local line = readNextLine()
        if not line then
            print("[ERROR] Unexpected end of file reading frame " .. frameIndex)
            return nil
        end
        fg_lines[i] = line
    end
    
    -- Read background color lines
    local bg_lines = {}
    for i = 1, numLines do
        local line = readNextLine()
        if not line then
            print("[ERROR] Unexpected end of file reading frame " .. frameIndex)
            return nil
        end
        bg_lines[i] = line
    end
    
    return {
        text = text_lines,
        fg = fg_lines,
        bg = bg_lines
    }
end

-- Display a single frame
displayFrame = function(frame)
    if not frame then
        print("[ERROR] Missing frame data")
        return 0
    end
    
    local startDrawTime = getTimeMs()
    
    -- Display each line of the frame
    for i = 1, #frame.text do
        monitor.setCursorPos(startX, startY + i - 1)
        monitor.blit(frame.text[i], frame.fg[i], frame.bg[i])
    end
    
    local endDrawTime = getTimeMs()
    local drawTime = endDrawTime - startDrawTime
    
    return drawTime
end

-- Close the video file
local function closeVideoFile()
    if videoFile then
        videoFile.close()
        videoFile = nil
    end
    
    -- Clear decompression data
    decompressedData = nil
    decompressPosition = 1
end

-- Wait for a redstone signal from any side
waitForRedstoneSignal = function()
    print("[WAIT] Waiting for redstone signal on any side...")
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Waiting for redstone signal...")
    
    -- Check if we already have a redstone signal
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    local hasSignalNow = false
    
    for _, side in ipairs(sides) do
        if redstone.getInput(side) then
            hasSignalNow = true
            break
        end
    end
    
    -- If we already have a signal, wait for it to turn off first
    if hasSignalNow then
        print("[WAIT] Redstone signal already on, waiting for it to turn off...")
        monitor.setCursorPos(1, 2)
        monitor.write("Signal already on, waiting for it to turn off...")
        
        local signalOff = false
        while not signalOff do
            signalOff = true
            for _, side in ipairs(sides) do
                if redstone.getInput(side) then
                    signalOff = false
                    break
                end
            end
            
            if not signalOff then
                os.sleep(0.1)
            end
        end
        
        print("[WAIT] Signal turned off, now waiting for it to turn on...")
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Waiting for redstone signal...")
    end
    
    -- Now wait for the signal to turn on
    while true do
        for _, side in ipairs(sides) do
            if redstone.getInput(side) then
                print("[START] Redstone signal detected on side: " .. side)
                monitor.clear()
                monitor.setCursorPos(1, 1)
                monitor.write("Signal received! Starting playback...")
                os.sleep(1) -- Brief pause to show the message
                return getTimeMs()
            end
        end
        
        os.sleep(0.1) -- Check every 100ms
    end
end

-- Play a video part with precise timing
local function playVideoPart(part)
    local path = getVideoPath(part)
    
    -- Download if needed
    if not fs.exists(path) then
        print("[INFO] Video part " .. part .. " not found, downloading...")
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Downloading video part " .. part .. "...")
        
        if not downloadVideo(part) then
            print("[ERROR] Failed to download part " .. part)
            monitor.clear()
            monitor.setCursorPos(1, 1)
            monitor.write("Download failed! Check the console.")
            return false
        end
    end
    
    -- Open video file and read header
    if not openVideoFile(path) then
        print("[ERROR] Failed to open video part " .. part)
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Failed to open video file! Check the console.")
        return false
    end
    
    print("[PLAY] Starting playback of part " .. part .. " with " .. totalFrames .. " frames")
    print("[PLAY] Target FPS: " .. FPS .. " (" .. FRAME_TIME_MS .. "ms per frame)")
    
    -- Initialize timing variables
    local startTimeMs = getTimeMs()
    local targetFrameTimeMs = FRAME_TIME_MS
    local currentFrameStartMs = startTimeMs
    local nextFrameTargetMs = startTimeMs
    
    -- Track timing statistics
    local totalDriftMs = 0
    local maxDriftMs = 0
    local totalProcessTimeMs = 0
    
    -- Clear the monitor before starting
    monitor.clear()
    
    -- Play all frames with precise timing
    for frameIndex = 1, totalFrames do
        -- Calculate target time for this frame
        nextFrameTargetMs = startTimeMs + ((frameIndex - 1) * targetFrameTimeMs)
        
        -- Get actual frame start time
        currentFrameStartMs = getTimeMs()
        
        -- Calculate drift
        local driftMs = currentFrameStartMs - nextFrameTargetMs
        totalDriftMs = totalDriftMs + math.abs(driftMs)
        maxDriftMs = math.max(maxDriftMs, math.abs(driftMs))
        
        -- Load and display the current frame, measuring time taken
        local frameLoadStartMs = getTimeMs()
        local frameData = loadAndDecodeFrame(frameIndex)
        local drawTimeMs = displayFrame(frameData)
        local totalProcessTimeForThisFrameMs = getTimeMs() - frameLoadStartMs
        totalProcessTimeMs = totalProcessTimeMs + totalProcessTimeForThisFrameMs
        
        -- Calculate when the next frame should be displayed
        local nextFrameTimeMs = nextFrameTargetMs + targetFrameTimeMs
        
        -- Log timing information periodically
        if frameIndex % 10 == 0 or frameIndex == 1 then
            print(string.format("[FRAME] %d/%d - Drift: %dms, Process: %dms", 
                frameIndex, totalFrames, driftMs, totalProcessTimeForThisFrameMs))
        end
        
        -- Sleep precisely until the next frame should be displayed
        compensatedSleep(nextFrameTimeMs)
    end
    
    -- Calculate and display performance statistics
    local totalTimeMs = getTimeMs() - startTimeMs
    local avgDriftMs = totalDriftMs / totalFrames
    local avgProcessTimeMs = totalProcessTimeMs / totalFrames
    local actualFps = 1000 * totalFrames / totalTimeMs
    
    print(string.format("[STATS] Playback complete - Frames: %d, Time: %.2fs", 
        totalFrames, totalTimeMs/1000))
    print(string.format("[STATS] Target FPS: %.2f, Actual FPS: %.2f", 
        FPS, actualFps))
    print(string.format("[STATS] Avg Process Time: %.2fms, Avg Drift: %.2fms, Max Drift: %dms", 
        avgProcessTimeMs, avgDriftMs, maxDriftMs))
    
    -- Close the file
    closeVideoFile()
    
    -- Clean up
    fs.delete(path)
    
    return true
end

-- Preload the next part while playing the current one
local function preloadNextPart(nextPart)
    local nextPath = getVideoPath(nextPart)
    if not fs.exists(nextPath) then
        return downloadVideo(nextPart)
    end
    return true
end

-- Main playback function
local function startPlayback()
    print("=== Memory-Optimized CC Video Player ===")
    print("Target FPS: " .. FPS .. " (" .. FRAME_TIME_MS .. "ms per frame)")
    print("=======================================")
    
    -- Wait for redstone signal to start
    local startTimeMs = waitForRedstoneSignal()
    print("[START] Playback started at: " .. startTimeMs .. "ms")
    
    -- Main playback loop
    isPlaying = true
    while isPlaying do
        -- Play current part
        local success = playVideoPart(currentPart)
        if not success then
            print("[ERROR] Failed to play part " .. currentPart)
            isPlaying = false
            break
        end
        
        -- Prepare for next part
        currentPart = currentPart + 1
        
        -- Try to preload next part
        local nextPath = getVideoPath(currentPart)
        if not fs.exists(nextPath) then
            print("[INFO] Attempting to preload part " .. currentPart)
            preloadNextPart(currentPart)
        end
    end
    
    print("[EXIT] Playback finished")
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Playback complete! Send another")
    monitor.setCursorPos(1, 2)
    monitor.write("redstone signal to play again.")
    
    -- Wait for another redstone signal to restart
    waitForRedstoneSignal()
    
    -- Reset state and restart playback
    currentPart = 1
    startPlayback()
end

-- Start the player
startPlayback()
