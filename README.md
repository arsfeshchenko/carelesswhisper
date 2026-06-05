```
    ____
   /    \
  | o  o |    C A R E L E S S   W H I S P E R
  |  __  |    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   \    /     squawk to type — or feed it a 3-hour podcast
    |  |
   /|  |\
```

# CarelessWhisper 🦜

### Powered by [OpenAI Whisper](https://platform.openai.com/docs/guides/speech-to-text) — a macOS menu bar app that turns your voice (or any audio file you throw at it) into text.

Speech-to-text is done by **OpenAI's Whisper API**. The speaker-labeling and paragraph-splitting pass uses **GPT-4o-mini**. Bring your own OpenAI API key — it lives locally on your Mac and is only sent to OpenAI for these two calls.

## Push-to-talk mode

1. **Hold** right ⌥ Option
2. **Speak** your mind (or mumble, it's fine)
3. **Release** — Whisper transcribes via OpenAI
4. **Boom** — text gets pasted wherever your cursor is

Hold **⇧ Shift** while releasing to suppress auto-submit for that one message. Tap **⎋ Esc** to cancel mid-recording.

Enable **Auto-submit (Enter)** in the menu and it'll also hit Enter after pasting. Like a parrot that not only repeats you but also sends the message before you can regret it.

## File transcribe mode

Click **Transcribe Audio File…** in the menu, point at an `.m4a` / `.mp3` / `.wav` / `.mp4` (up to several hours), and CarelessWhisper will:

1. Split the audio into 5-minute chunks (passthrough for m4a — no re-encode, near-instant)
2. Send each chunk to **OpenAI's Whisper API** in Ukrainian mode for transcription
3. Pass the joined transcript through **OpenAI's GPT-4o-mini** to break it into paragraphs and label each speaker — not as boring "Speaker 1" / "Speaker 2", but as a **random bird**: Сокіл, Сова, Орел, Журавель, Ластівка, Лелека, Дятел… The same person keeps the same bird throughout the whole transcript, recognised by conversational cues across chunks.
4. Save the result as `<filename>.txt` next to the source and open it in TextEdit.

A floating progress window shows live upload %, processing, and chunk counts. Cancel any time.

Sample output:

```
Сокіл: Привіт, як справи?

Журавель: Все добре, дякую. А в тебе?

Сокіл: Теж непогано.
```

## The bird lives in your menu bar

No dock icon. No window. Just a tiny bird up top, waiting to repeat everything you say — or anything you record.
