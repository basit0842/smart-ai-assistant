require "import"
import "android.widget.*"
import "android.view.*"
import "android.content.*"
import "android.graphics.Color"
import "android.graphics.drawable.GradientDrawable"
import "android.graphics.drawable.ColorDrawable"
import "android.graphics.Typeface"
import "java.io.File"
import "com.androlua.Http"
import "android.text.TextWatcher"
import "android.speech.SpeechRecognizer"
import "android.speech.RecognizerIntent"
import "android.speech.RecognitionListener"
import "android.net.Uri"
import "android.speech.tts.TextToSpeech"
import "android.speech.tts.UtteranceProgressListener"
import "android.os.Bundle"
import "android.os.Handler"
import "android.os.Looper"
import "android.media.RingtoneManager"

local json = require "cjson"

-- Folder and configuration path
local folderPath = os.getenv("EXTERNAL_STORAGE") .. "/Copilot by Tayyab/"
local folder = File(folderPath)
if not folder.exists() then
  folder.mkdirs()
end
local savePath = folderPath .. "app_config.json"

-- Load settings
local function loadSettings()
  local f = io.open(savePath, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, content)
    if ok then return data end
  end
  return {
    model = "Standard",
    lang = "Urdu",
    historyEnabled = true,
    autoReadEnabled = true,
    sysPromptEnabled = false,
    sysPromptText = "Act as a helpful assistant.",
    ttsRate = 1.0,
    ttsPitch = 1.0,
    selectedTtsEngine = ""
  }
end

local config = loadSettings()
local curModel = config.model or "Standard"
local curLang = config.lang or "Urdu"

local historyEnabled = config.historyEnabled
if historyEnabled == nil then historyEnabled = true end

local autoReadEnabled = config.autoReadEnabled
if autoReadEnabled == nil then autoReadEnabled = true end

local sysPromptEnabled = config.sysPromptEnabled
if sysPromptEnabled == nil then sysPromptEnabled = false end

local sysPromptText = config.sysPromptText or ""
local ttsRate = config.ttsRate or 1.0
local ttsPitch = config.ttsPitch or 1.0
local selectedTtsEngine = config.selectedTtsEngine or ""

-- Global Status Controls
local chatHistory = {}
local ttsEngine = nil
local isTtsSpeaking = false
local isTtsPaused = false
local currentSpeakingUtterance = nil
local currentSpeakingPosition = 0
local isPausingExplicitly = false
local installedTtsEngines = {}
local installedTtsLabels = {}

-- Advanced TTS alert helper to replace visual Toast announcements for Screen Readers
local function speakAlert(text)
  if ttsEngine then
    local params = Bundle()
    params.putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, "AlertUtterance")
    ttsEngine.speak(text, TextToSpeech.QUEUE_FLUSH, params, "AlertUtterance")
  else
    -- Fallback to toast if TTS engine is not initialized yet
    Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
  end
end

-- Text to Speech Progress Listener (Advanced Pause/Resume support)
local function setTtsProgressListener()
  if not ttsEngine then return end
  ttsEngine.setOnUtteranceProgressListener(UtteranceProgressListener{
    onStart = function(utteranceId)
      isTtsSpeaking = true
      isTtsPaused = false
    end,
    onDone = function(utteranceId)
      if isPausingExplicitly then
        isPausingExplicitly = false
        return
      end
      isTtsSpeaking = false
      isTtsPaused = false
      currentSpeakingUtterance = nil
      currentSpeakingPosition = 0
    end,
    onError = function(utteranceId)
      if isPausingExplicitly then
        isPausingExplicitly = false
        return
      end
      isTtsSpeaking = false
      isTtsPaused = false
      currentSpeakingUtterance = nil
      currentSpeakingPosition = 0
    end,
    onStop = function(utteranceId, interrupted)
      if isPausingExplicitly then
        isPausingExplicitly = false
        return
      end
      isTtsSpeaking = false
      isTtsPaused = false
      currentSpeakingUtterance = nil
      currentSpeakingPosition = 0
    end,
    onRangeStart = function(utteranceId, start, end_offset, frame)
      currentSpeakingPosition = start
    end
  })
end

local function initTtsEngine(enginePackage)
  if ttsEngine then
    ttsEngine.shutdown()
    ttsEngine = nil
  end
  local initListener = TextToSpeech.OnInitListener{
    onInit = function(status)
      if status == TextToSpeech.SUCCESS then
        ttsEngine.setSpeechRate(ttsRate)
        ttsEngine.setPitch(ttsPitch)
        setTtsProgressListener()
      end
    end
  }
  if enginePackage and enginePackage ~= "" then
    ttsEngine = TextToSpeech(this, initListener, enginePackage)
  else
    ttsEngine = TextToSpeech(this, initListener)
  end
end

-- Fetch installed TTS engines
local function fetchInstalledTtsEngines()
  installedTtsEngines = {}
  installedTtsLabels = {}
  table.insert(installedTtsEngines, "")
  table.insert(installedTtsLabels, "System Default Engine")
  pcall(function()
    if ttsEngine and ttsEngine.getEngines then
      local engines = ttsEngine.getEngines()
      if engines then
        local iterator = engines.iterator()
        while iterator.hasNext() do
          local info = iterator.next()
          table.insert(installedTtsEngines, tostring(info.name))
          table.insert(installedTtsLabels, tostring(info.label))
        end
      end
    end
  end)
end

initTtsEngine(selectedTtsEngine)
Handler(Looper.getMainLooper()).post(Runnable({
  run = function()
    fetchInstalledTtsEngines()
  end
}))

local langCodes = {
  Urdu="ur-PK", English="en-US", Hindi="hi-IN", Arabic="ar-SA", Punjabi="pa-PK",
  Pashto="ps-PK", Sindhi="sd-PK", Persian="fa-IR", Spanish="es-ES", French="fr-FR",
  German="de-DE", Chinese="zh-CN", Japanese="ja-JP", Russian="ru-RU", Turkish="tr-TR",
  Portuguese="pt-PT", Italian="it-IT", Bengali="bn-BD", Korean="ko-KR", Indonesian="id-ID"
}

local activeAccent = Color.parseColor("#00E676")
local UI = {
  bg = Color.parseColor("#050505"),
  card = Color.parseColor("#121212"),
  userMsg = Color.parseColor("#004D40"),
  aiMsg = Color.parseColor("#1E1E1E"),
  text = Color.parseColor("#FFFFFF"),
  hint = Color.parseColor("#888888"),
  trans = Color.TRANSPARENT
}

local function saveSettings()
  local f = io.open(savePath, "w")
  if f then
    f:write(json.encode({
      model=curModel,
      lang=curLang,
      historyEnabled=historyEnabled,
      autoReadEnabled=autoReadEnabled,
      sysPromptEnabled=sysPromptEnabled,
      sysPromptText=sysPromptText,
      ttsRate=ttsRate,
      ttsPitch=ttsPitch,
      selectedTtsEngine=selectedTtsEngine
    }))
    f:close()
  end
end

local function getShape(colorInt, rad)
  local s = GradientDrawable()
  s.setColor(colorInt)
  s.setCornerRadius(rad or 30)
  return s
end

local function viber(ms)
  local vb = this.getSystemService(Context.VIBRATOR_SERVICE)
  if vb then
    vb.vibrate(ms or 50)
  end
end

-- Play brief notification sound helper
local function playNotificationSound()
  pcall(function()
    local notificationUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
    local r = RingtoneManager.getRingtone(this, notificationUri)
    if r then
      r.play()
    end
  end)
end

-- Text Cleaning Filter (Removes hashes, stars, em-dashes, and formats text for natural TTS output)
local function cleanText(str)
  if not str then return "" end
  
  -- Replace em-dash with a space so TTS pauses naturally instead of slurring words together
  str = str:gsub("—", " ")
  
  -- Remove markdown heading hashes (###) and general hashes
  str = str:gsub("#", "")
  
  -- Remove stars/asterisks (used in markdown formatting)
  str = str:gsub("%*", "")
  
  -- Remove backticks
  str = str:gsub("`", "")
  
  -- Remove standard dashes if they are separators
  str = str:gsub(" %- ", " ")
  str = str:gsub(" %-%- ", " ")
  
  -- Trim leading/trailing whitespace
  str = str:gsub("^%s*(.-)%s*$", "%1")
  
  return str
end

-- Main Interface Layout
local mainLayout = {
  FrameLayout,
  id = "rootFrame",
  layout_width = "fill",
  layout_height = "fill",
  { RelativeLayout,
    id = "mainContent",
    layout_width = "fill",
    layout_height = "fill",
    backgroundColor = UI.bg,
    -- Top Bar
    { LinearLayout,
      id = "topBar",
      layout_width = "fill",
      padding = "12dp",
      backgroundColor = UI.card,
      gravity = "center_vertical",
      layout_alignParentTop = true,
      { ImageButton,
        id = "menuBtn",
        contentDescription = "Clear Chat",
        background = ColorDrawable(UI.trans),
        layout_width = "45dp",
        layout_height = "45dp",
        padding = "10dp",
        colorFilter = activeAccent
      },
      { TextView,
        id = "titleTxt",
        text = "Copilot Chat",
        textColor = activeAccent,
        textSize = "17sp",
        Typeface = Typeface.DEFAULT_BOLD,
        layout_weight = 1,
        layout_marginLeft = "10dp"
      },
      { Button,
        text = "SETTINGS",
        id = "setBtn",
        contentDescription = "Open Settings",
        background = getShape(activeAccent, 15),
        textColor = Color.BLACK,
        textSize = "11sp",
        layout_width = "90dp",
        layout_height = "38dp"
      }
    },
    -- Bottom Bar
    { LinearLayout,
      id = "bottomBar",
      layout_width = "fill",
      padding = "10dp",
      backgroundColor = UI.card,
      layout_alignParentBottom = true,
      gravity = "center_vertical",
      { EditText,
        id = "input",
        layout_weight = 1,
        hint = "Type a message...",
        hintTextColor = UI.hint,
        textColor = UI.text,
        background = getShape(Color.parseColor("#1A1A1A"), 50),
        padding = "14dp",
        textSize = "15sp"
      },
      { ImageButton,
        id = "micBtn",
        contentDescription = "Voice Input",
        layout_marginLeft = "8dp",
        background = ColorDrawable(UI.trans),
        padding = "10dp",
        layout_width = "45dp",
        layout_height = "45dp",
        colorFilter = activeAccent
      },
      { ImageButton,
        id = "sendBtn",
        contentDescription = "Send Message",
        layout_marginLeft = "8dp",
        background = getShape(activeAccent, 100),
        padding = "12dp",
        layout_width = "50dp",
        layout_height = "50dp"
      }
    },
    -- Chat screen list (Scrollable)
    { ScrollView,
      id = "scroll",
      layout_below = "topBar",
      layout_above = "bottomBar",
      fillViewport = true,
      { LinearLayout,
        id = "chatList",
        orientation = "vertical",
        padding = "12dp",
        layout_width = "fill",
        layout_height = "wrap"
      }
    }
  }
}

local dlg = LuaDialog(this)
-- direct global binding environment for Jieshuo
local view = loadlayout(mainLayout)
dlg.setView(view)
menuBtn.setImageResource(android.R.drawable.ic_menu_delete)
sendBtn.setImageResource(android.R.drawable.ic_menu_send)
micBtn.setImageResource(android.R.drawable.ic_btn_speak_now)
dlg.show()

local window = dlg.getWindow()
window.setBackgroundDrawable(ColorDrawable(UI.bg))
window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
window.getDecorView().setPadding(0, 0, 0, 0)

-- Chat clear button
menuBtn.onClick = function()
  viber(40)
  if ttsEngine then
    ttsEngine.stop()
  end
  isTtsSpeaking = false
  isTtsPaused = false
  currentSpeakingUtterance = nil
  currentSpeakingPosition = 0
  chatList.removeAllViews()
  speakAlert("Chat cleared")
end

-- Speech to Text (Microphone) engine
local recognizer = SpeechRecognizer.createSpeechRecognizer(this)
recognizer.setRecognitionListener(RecognitionListener{
  onResults=function(results)
    local matches = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
    if matches and matches.size() > 0 then
      input.setText(matches.get(0))
    end
    micBtn.setColorFilter(activeAccent)
    micBtn.setContentDescription("Voice Input")
  end,
  onReadyForSpeech=function()
    Toast.makeText(this, "Listening...", Toast.LENGTH_SHORT).show()
    micBtn.setColorFilter(Color.RED)
    micBtn.setContentDescription("Listening...")
  end,
  onError=function()
    micBtn.setColorFilter(activeAccent)
    micBtn.setContentDescription("Voice Input")
    speakAlert("Speech recognition failed")
  end,
  onEndOfSpeech=function()
    micBtn.setColorFilter(activeAccent)
    micBtn.setContentDescription("Voice Input")
  end
})

micBtn.onClick = function()
  viber(50)
  micBtn.setContentDescription("Listening...")
  local recognizerIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
  recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
  local code = langCodes[curLang] or "ur-PK"
  recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, code)
  recognizer.startListening(recognizerIntent)
end

-- Smart Audio Manager (Advanced Pause/Resume support)
local function handleTtsSpeech(textToSpeak)
  if ttsEngine == nil then return end
  local params = Bundle()
  params.putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, "CopilotUtterance")
  
  if isTtsSpeaking then
    if currentSpeakingUtterance == textToSpeak then
      if not isTtsPaused then
        -- Pause the audio
        isPausingExplicitly = true
        ttsEngine.stop()
        isTtsPaused = true
        isTtsSpeaking = true
        speakAlert("Speech paused")
      else
        -- Resume the audio from the exact saved position
        local resumeText = textToSpeak
        if currentSpeakingPosition and currentSpeakingPosition > 0 then
          resumeText = textToSpeak:sub(currentSpeakingPosition + 1)
        end
        if #resumeText == 0 then
          resumeText = textToSpeak
          currentSpeakingPosition = 0
        end
        ttsEngine.speak(resumeText, TextToSpeech.QUEUE_FLUSH, params, "CopilotUtterance")
        isTtsPaused = false
        isTtsSpeaking = true
        speakAlert("Speech resumed")
      end
    else
      -- User clicked on a different message, stop previous and play new from start
      ttsEngine.stop()
      currentSpeakingPosition = 0
      ttsEngine.speak(textToSpeak, TextToSpeech.QUEUE_FLUSH, params, "CopilotUtterance")
      currentSpeakingUtterance = textToSpeak
      isTtsPaused = false
      isTtsSpeaking = true
    end
  else
    -- Standard click playback
    currentSpeakingPosition = 0
    ttsEngine.speak(textToSpeak, TextToSpeech.QUEUE_FLUSH, params, "CopilotUtterance")
    currentSpeakingUtterance = textToSpeak
    isTtsSpeaking = true
    isTtsPaused = false
  end
end

function addMsg(role, msg)
  local isU = (role == "You")
  local mlp = LinearLayout.LayoutParams(-2, -2)
  mlp.setMargins(10, 15, 10, 15)
  mlp.gravity = isU and Gravity.RIGHT or Gravity.LEFT
  
  local card = LinearLayout(this)
  card.setPadding(35, 25, 35, 25)
  card.setLayoutParams(mlp)
  
  local cornerRadius = 45
  local bubbleShape = GradientDrawable()
  bubbleShape.setColor(isU and UI.userMsg or UI.aiMsg)
  if isU then
    bubbleShape.setCornerRadii({cornerRadius, cornerRadius, 0, 0, cornerRadius, cornerRadius, cornerRadius, cornerRadius})
  else
    bubbleShape.setCornerRadii({0, 0, cornerRadius, cornerRadius, cornerRadius, cornerRadius, cornerRadius, cornerRadius})
  end
  card.setBackground(bubbleShape)
  
  local t = TextView(this)
  t.setText(msg)
  t.setTextColor(UI.text)
  t.setTextSize(15)
  t.setTextIsSelectable(false)
  card.addView(t)
  chatList.addView(card)
  
  scroll.post(Runnable({run=function()
    scroll.fullScroll(View.FOCUS_DOWN)
  end}))
  
  card.onClick = function()
    viber(40)
    handleTtsSpeech(msg)
  end
  
  card.onLongClick = function()
    viber(80)
    local clipboard = this.getSystemService(Context.CLIPBOARD_SERVICE)
    local clip = ClipData.newPlainText("Copilot Text", msg)
    clipboard.setPrimaryClip(clip)
    speakAlert("Copied to clipboard")
    return true
  end
  
  if not isU then
    viber(60)
  end
end

-- API Network Manager
function callYupraAI(txt)
  addMsg("You", txt)
  
  local loadCard = LinearLayout(this)
  loadCard.setPadding(35, 25, 35, 25)
  local loadMlp = LinearLayout.LayoutParams(-2, -2)
  loadMlp.setMargins(10, 15, 10, 15)
  loadMlp.gravity = Gravity.LEFT
  loadCard.setLayoutParams(loadMlp)
  loadCard.setBackground(getShape(UI.aiMsg, 45))
  
  local loadText = TextView(this)
  loadText.setText("Thinking...")
  loadText.setTextColor(activeAccent)
  loadText.setTypeface(Typeface.DEFAULT_BOLD)
  loadCard.addView(loadText)
  chatList.addView(loadCard)
  
  scroll.post(Runnable({run=function()
    scroll.fullScroll(View.FOCUS_DOWN)
  end}))
  
  local conversationContext = ""
  if sysPromptEnabled and sysPromptText ~= "" then
    conversationContext = "System Instruction: " .. sysPromptText .. "\n"
  end
  
  if historyEnabled then
    table.insert(chatHistory, { role = "User", content = txt })
    
    -- Keep trimming from the oldest history messages until the encoded string is safe under 7000 characters
    while true do
      local tempContext = ""
      if sysPromptEnabled and sysPromptText ~= "" then
        tempContext = "System Instruction: " .. sysPromptText .. "\n"
      end
      for _, msg in ipairs(chatHistory) do
        tempContext = tempContext .. msg.role .. ": " .. msg.content .. "\n"
      end
      
      local encodedLength = #tostring(Uri.encode(tempContext))
      if encodedLength <= 7000 or #chatHistory <= 1 then
        conversationContext = tempContext
        break
      else
        table.remove(chatHistory, 1) -- Remove the oldest message from history memory
      end
    end
  else
    local tempContext = conversationContext .. "User: " .. txt
    local encodedLength = #tostring(Uri.encode(tempContext))
    if encodedLength > 7000 then
      local truncatedTxt = txt
      while #tostring(Uri.encode(conversationContext .. "User: " .. truncatedTxt)) > 7000 and #truncatedTxt > 10 do
        truncatedTxt = truncatedTxt:sub(1, #truncatedTxt - 50)
      end
      conversationContext = conversationContext .. "User: " .. truncatedTxt
    else
      conversationContext = tempContext
    end
  end
  
  local baseUrl = "https://api.yupra.my.id/api/ai/copilot?text="
  if curModel == "Thinking" then
    baseUrl = "https://api.yupra.my.id/api/ai/copilot-think?text="
  end
  
  local finalUrl = baseUrl .. Uri.encode(conversationContext)
  
  Http.get(finalUrl, function(code, res)
    chatList.removeView(loadCard)
    if code == 200 then
      local reply = res
      local ok, d = pcall(json.decode, res)
      if ok and d then
        reply = d.result or d.response or d.data or d.reply or res
      end
      
      -- Filter annoying asterisks, hashes, and dashes from AI reply
      if reply then
        reply = cleanText(tostring(reply))
      end
      
      addMsg("AI", reply)
      
      if historyEnabled then
        table.insert(chatHistory, { role = "AI", content = reply })
        while #chatHistory > 8 do
          table.remove(chatHistory, 1)
        end
      end
      
      -- Play brief notification sound
      playNotificationSound()
      
      -- Auto Read if enabled
      if autoReadEnabled then
        Handler(Looper.getMainLooper()).postDelayed(Runnable({
          run = function()
            handleTtsSpeech(reply)
          end
        }), 300)
      end
      
    else
      -- Highly robust and friendly error messages for the user
      local errorMsg = ""
      if code == 500 then
        errorMsg = "The server is currently busy due to very high traffic. Please try sending your message again."
      elseif code == 414 then
        errorMsg = "Your message is too long for the server to process. Please try shortening your message."
      elseif code == 404 then
        errorMsg = "The AI endpoint could not be reached. Please try again later."
      else
        errorMsg = "A network error occurred. Please check your internet connection and try again."
      end
      
      addMsg("AI", errorMsg)
      playNotificationSound()
      
      -- Speak the error message directly to the screen reader user
      speakAlert(errorMsg)
    end
  end)
end

sendBtn.onClick = function()
  viber(30)
  local s = tostring(input.Text)
  if #s:gsub("%s+", "") == 0 then
    speakAlert("Please type something")
  else
    callYupraAI(s)
    input.Text = ""
  end
end

-- Simple Settings Panel
setBtn.onClick = function()
  viber(50)
  fetchInstalledTtsEngines()
  
  local sLayout = {
    ScrollView,
    layout_width = "fill",
    layout_height = "fill",
    backgroundColor = UI.card,
    { LinearLayout,
      id = "dialogRoot",
      orientation = "vertical",
      padding = "25dp",
      layout_width = "fill",
      {TextView, text="SETTINGS", textSize="18sp", textColor=activeAccent, gravity="center", paddingBottom="20dp", Typeface=Typeface.DEFAULT_BOLD, layout_width="fill"},
      {TextView, text="AI Model:", textColor=UI.text, textSize="13sp", layout_marginBottom="5dp"},
      {Spinner, id="modelSpinner", layout_width="fill", layout_marginBottom="15dp"},
      {TextView, text="Language:", textColor=UI.text, textSize="13sp", layout_marginBottom="5dp"},
      {Spinner, id="langSpinner", layout_width="fill", layout_marginBottom="20dp"},
      {CheckBox, id="histCheck", text="Save Chat History", textColor=activeAccent, layout_marginBottom="15dp"},
      {CheckBox, id="autoReadCheck", text="Auto Read Message", textColor=activeAccent, layout_marginBottom="15dp"},
      {CheckBox, id="sysPromptCheck", text="Use Custom System Prompt", textColor=activeAccent, layout_marginBottom="5dp"},
      {EditText, id="sysPromptInput", hint="Enter system instructions...", textColor=UI.text, hintTextColor=UI.hint, background=getShape(Color.parseColor("#1A1A1A"), 15), padding="12dp", textSize="14sp", layout_width="fill", layout_marginBottom="20dp"},
      {TextView, text="TEXT TO SPEECH (TTS) SETTINGS", textSize="14sp", textColor=activeAccent, Typeface=Typeface.DEFAULT_BOLD, layout_marginBottom="10dp"},
      {TextView, text="Select TTS Engine:", textColor=UI.text, textSize="13sp", layout_marginBottom="5dp"},
      {Spinner, id="engineSpinner", layout_width="fill", layout_marginBottom="15dp"},
      {TextView, text="Speech Speed (Rate):", textColor=UI.text, textSize="12sp"},
      {SeekBar, id="rateSeekBar", layout_width="fill", layout_marginBottom="15dp"},
      {TextView, text="Speech Pitch:", textColor=UI.text, textSize="12sp"},
      {SeekBar, id="pitchSeekBar", layout_width="fill", layout_marginBottom="25dp"},
      {Button, id="clearHistBtn", text="CLEAR CHAT MEMORY", background=getShape(Color.parseColor("#D32F2F"), 15), textColor=Color.WHITE, layout_width="fill", layout_height="45dp", layout_marginBottom="15dp"},
      {Button, id="aboutBtn", text="HELP & MANUAL", background=getShape(Color.parseColor("#1976D2"), 15), textColor=Color.WHITE, layout_width="fill", layout_height="45dp", layout_marginBottom="25dp"},
      { LinearLayout,
        orientation="horizontal",
        layout_width="fill",
        gravity="center",
        {Button, id="cancelSetBtn", text="CANCEL", background=getShape(Color.parseColor("#424242"), 15), textColor=Color.WHITE, layout_weight=1, layout_marginRight="10dp", layout_height="48dp"},
        {Button, id="saveSetBtn", text="SAVE CHANGES", background=getShape(activeAccent, 15), textColor=Color.BLACK, layout_weight=1, layout_height="48dp"}
      }
    }
  }
  
  local sDlg = LuaDialog(this)
  local sView = loadlayout(sLayout)
  sDlg.setView(sView)
  
  local modelsList = {"Standard", "Thinking"}
  modelSpinner.setAdapter(ArrayAdapter(this, android.R.layout.simple_spinner_item, modelsList))
  for i, v in ipairs(modelsList) do
    if v == curModel then
      modelSpinner.setSelection(i-1)
    end
  end
  
  local sortedLanguages = {}
  for k, _ in pairs(langCodes) do
    table.insert(sortedLanguages, k)
  end
  table.sort(sortedLanguages)
  
  langSpinner.setAdapter(ArrayAdapter(this, android.R.layout.simple_spinner_item, sortedLanguages))
  for i, v in ipairs(sortedLanguages) do
    if v == curLang then
      langSpinner.setSelection(i-1)
    end
  end
  
  engineSpinner.setAdapter(ArrayAdapter(this, android.R.layout.simple_spinner_item, installedTtsLabels))
  for i, pkg in ipairs(installedTtsEngines) do
    if pkg == selectedTtsEngine then
      engineSpinner.setSelection(i-1)
    end
  end
  
  histCheck.setChecked(historyEnabled)
  autoReadCheck.setChecked(autoReadEnabled)
  sysPromptCheck.setChecked(sysPromptEnabled)
  sysPromptInput.setText(sysPromptText)
  sysPromptInput.setVisibility(sysPromptEnabled and View.VISIBLE or View.GONE)
  
  sysPromptCheck.onClick = function(v)
    sysPromptInput.setVisibility(v.isChecked() and View.VISIBLE or View.GONE)
  end
  
  rateSeekBar.setMax(20)
  rateSeekBar.setProgress(math.floor(ttsRate * 10))
  pitchSeekBar.setMax(20)
  pitchSeekBar.setProgress(math.floor(ttsPitch * 10))
  
  clearHistBtn.onClick = function()
    viber(70)
    chatHistory = {}
    speakAlert("Memory cleared")
  end
  
  -- Easy Guidebook
  aboutBtn.onClick = function()
    viber(40)
    local aLayout = {
      ScrollView,
      layout_width = "fill",
      layout_height = "fill",
      backgroundColor = UI.card,
      { LinearLayout,
        id = "aboutRoot",
        orientation = "vertical",
        padding = "25dp",
        layout_width = "fill",
        {TextView, text="USER MANUAL", textSize="18sp", textColor=activeAccent, gravity="center", paddingBottom="15dp", Typeface=Typeface.DEFAULT_BOLD, layout_width="fill"},
        {TextView, text="HOW TO USE:\n1. Type your text inside the input box and click the Send button to get answers from AI.\n2. Tap the Microphone button to input text using your voice.\n\nAUDIO PLAYS:\n1. Single Tap: Click once on any message to read it out loud through Text-To-Speech (TTS). Click again while playing to Pause it.\n2. Long Press: Press and hold any message block to copy that text directly to your clipboard.", textColor=UI.text, textSize="14sp", layout_marginBottom="25dp"},
        {Button, id="closeAboutBtn", text="OK", background=getShape(activeAccent, 15), textColor=Color.BLACK, layout_width="fill", layout_height="45dp"}
      }
    }
    local aDlg = LuaDialog(this)
    local aView = loadlayout(aLayout)
    aDlg.setView(aView)
    closeAboutBtn.onClick = function()
      viber(30)
      aDlg.dismiss()
    end
    aDlg.show()
  end
  
  cancelSetBtn.onClick = function()
    viber(30)
    sDlg.dismiss()
  end
  
  saveSetBtn.onClick = function()
    viber(40)
    curModel = modelsList[modelSpinner.getSelectedItemPosition() + 1]
    curLang = sortedLanguages[langSpinner.getSelectedItemPosition() + 1]
    historyEnabled = histCheck.isChecked()
    autoReadEnabled = autoReadCheck.isChecked()
    sysPromptEnabled = sysPromptCheck.isChecked()
    sysPromptText = sysPromptInput.getText().toString()
    
    local newEnginePkg = installedTtsEngines[engineSpinner.getSelectedItemPosition() + 1] or ""
    local engineChanged = (newEnginePkg ~= selectedTtsEngine)
    selectedTtsEngine = newEnginePkg
    
    local newRate = rateSeekBar.getProgress() / 10
    if newRate < 0.1 then newRate = 0.1 end
    ttsRate = newRate
    
    local newPitch = pitchSeekBar.getProgress() / 10
    if newPitch < 0.1 then newPitch = 0.1 end
    ttsPitch = newPitch
    
    if engineChanged then
      initTtsEngine(selectedTtsEngine)
    else
      if ttsEngine then
        ttsEngine.setSpeechRate(ttsRate)
        ttsEngine.setPitch(ttsPitch)
      end
    end
    
    saveSettings()
    sDlg.dismiss()
    speakAlert("Settings saved successfully")
  end
  
  sDlg.show()
end