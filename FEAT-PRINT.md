FEAT: PRINT
===========

NAME
  print — send a document to the Brother HL-L2350DW
  laser printer in Riga via SSH hop chain

WHEN
  when Mikael sends a PDF or docx to the chat and
  says print it

STEPS
  1. download the file from Telegram via TDLib
  2. if docx: SCP to Mac Mini (100.85.9.92), convert
     with textutil -convert html then Chrome headless
     --print-to-pdf. if PDF: skip conversion.
  3. SCP the PDF from Mac Mini to RPi5 "plank"
     (192.168.88.4 on LAN via Mac as jump host)
  4. ssh to plank via Mac:
     ssh mbrock@100.85.9.92 "ssh mbrock@192.168.88.4
     'lp -d Brother_HL_L2350DW /tmp/file.pdf'"
  5. check: lpstat -o on plank shows job completing

GIVES
  paper coming out of a printer in Riga

TEST
  if the job sits at "now printing" forever, check:
  - lpstat -v: should show ipp://localhost:60000/ipp/print
  - if it shows implicitclass://, cups-browsed lost
    the backend. fix: lpadmin -x old, lpadmin -p new
    -v ipp://localhost:60000/ipp/print -m everywhere -E
  - if lsusb shows Brother but usblp was removed,
    ipp-usb is handling the device. do NOT reload usblp.

NOTE
  the Brother is physically USB-connected to the RPi5
  ("plank" at 192.168.88.4 on the Riga LAN). ipp-usb
  daemon intercepts the USB device and speaks IPP to it
  on localhost:60000. the old cups-browsed implicitclass
  backend did not know about this and was broken for a
  month.

  the Mac Mini sees the printer via Bonjour (DNS-SD)
  but its ippusb:// URI assumes the printer is local
  USB on the Mac. it is not. the Mac cannot print to
  it directly until cupsctl --share-printers is enabled
  on plank.

  the SSH hop chain:
    charlie.1.foo (37.27.71.35, Falkenstein)
    -> mikaels-mac-mini-2 (100.85.9.92, Tailscale)
    -> plank (192.168.88.4, Riga LAN)
    -> Brother HL-L2350DW (USB, ipp-usb on :60000)

  conversion chain for docx:
    textutil -convert html (macOS built-in)
    -> Chrome --headless --print-to-pdf (macOS Chrome)
    -> PDF

KEBAB
  a thing of meat and bread and sauce. every document
  printed by this pipeline passes through three
  countries (Germany, Latvia, and whatever country the
  Telegram CDN served the file from) to reach one
  Brother laser printer. the kebab is warm.
