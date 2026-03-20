FEAT: PRINT
===========

NAME
  print — send a document to the Brother HL-L2350DW
  laser printer in Riga

WHEN
  when someone sends a PDF or docx to the chat and
  says print it

STEPS
  1. download the file from Telegram via TDLib
  2. if docx: SCP to Mac Mini (100.85.9.92), convert
     with textutil + Chrome headless --print-to-pdf.
     if PDF: use directly.
  3. SCP the PDF to plank over Tailscale:
     scp file.pdf mbrock@100.105.182.103:/tmp/
  4. print:
     ssh mbrock@100.105.182.103 \
       "lp -d Brother_HL_L2350DW /tmp/file.pdf"

GIVES
  paper coming out of a printer in Riga

TEST
  if the job sits at "now printing" forever, check:
  - lpstat -v on plank: should show
    ipp://localhost:60000/ipp/print
  - if it shows implicitclass://, cups-browsed lost
    the backend. fix: lpadmin -x old, then
    lpadmin -p Brother_HL_L2350DW \
      -v ipp://localhost:60000/ipp/print \
      -m everywhere -E
  - if lsusb shows Brother but usblp was removed,
    ipp-usb is handling the device. do NOT reload usblp.

NOTE
  plank is the RPi5 at 192.168.88.4 on the Riga LAN.
  it is now also on Tailscale at 100.105.182.103
  (hostname: plank, tailnet: whale-justice.ts.net).

  the Brother is USB-connected to plank. ipp-usb
  intercepts the USB device and speaks IPP on
  localhost:60000. CUPS on plank forwards to it.

  three print paths exist, from best to worst:

  1. TAILSCALE DIRECT (preferred)
     charlie.1.foo → plank (100.105.182.103)
     one SCP + one SSH lp. 95ms latency.
     no intermediary.

  2. MAC MINI IPP
     Mac Mini → plank (192.168.88.4:631)
     lp -d RPi_Brother on the Mac.
     works now that CUPS sharing is enabled on plank.

  3. MAC MINI SSH HOP (legacy, still works)
     charlie → Mac Mini → plank
     ssh mbrock@100.85.9.92 \
       "ssh mbrock@192.168.88.4 'lp ...'"

  for docx conversion, the Mac Mini is still needed
  (textutil is macOS-only). future: install libreoffice
  on plank or use Chromium on charlie.1.foo.

  CUPS sharing was enabled 2026-03-20:
    /usr/sbin/cupsctl --share-printers
    Port 631, Listen 0.0.0.0, Browsing On

  Tailscale was installed on plank 2026-03-20:
    tailscale v1.96.2, hostname plank,
    IP 100.105.182.103

KEBAB
  a thing of meat and bread and sauce. this document
  was printed from Falkenstein, Germany to Riga, Latvia
  via a mesh VPN tunnel that traverses no public
  internet. the kebab is warm. the printer is warm.
  the document is Latvian bureaucracy about mandatory
  library deposits.
