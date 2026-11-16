---
title: Message contacts directly
---

# Message contacts directly

The **Contacts** tab lists the nodes your radio knows: people (chat nodes),
repeaters, room servers and sensors. Each row shows the route to it (Flood or a
hop count), part of its public key and when it was last heard.

![Contact list](../assets/android/contacts.png)

Use the filter button at the top right to sort by latest message, last heard or
name, and to show only favorites, one kind of node, or contacts with unread
messages.

![Sort and filter](../assets/android/contacts-sort-and-filter.png)

## Add a contact

Nodes are added when your radio hears their advert, if automatic adding is on
for that kind of node (**Settings > Contacts**). Nodes heard but not added are in
the menu at the top right under **Discovered Contacts**.

![Contacts menu](../assets/android/contacts-menu.png)

The same menu can add a contact by public key or by scanning their QR code, and
shows **My contact QR** for others to scan. The QR's link works even if the other
person has never heard your advert.

![My contact QR](../assets/android/my-contact-qr.png)

## Let others find you

The broadcast button next to the menu sends your advert so other radios can add
you:

- **Zero Hop Advert** reaches only radios that hear you directly.
- **Flood Advert** is repeated across the mesh.

The same menu can copy your advert to the clipboard, or add a contact from an
advert someone else copied.

![Advert menu](../assets/android/contacts-advert-menu.png)

## Send a direct message

Tap a chat contact to open the conversation. Your sent messages show a check
mark once delivery is confirmed, and the round-trip time. A message that needed
another try shows its retry count.

![Direct chat](../assets/android/chat.png)

## Routing

The route button at the top of a chat chooses how messages reach this contact:

- **Auto (use saved path):** use the route learned from earlier messages, and
  flood when there isn't one.
- **Direct:** send with no repeaters. The message arrives only if the contact's
  radio hears yours directly.
- **Force Flood Mode:** always flood.

![Routing mode](../assets/android/chat-routing-mode.png)

## Contact menu

The menu at the top right of a chat has **Contact Info**, **Telemetry**,
**Contact Settings**, **Clear Chat** and **Block**.

![Contact menu](../assets/android/chat-menu.png)

**Contact Info** shows the node type, route, last-heard time, location and full
public key.

![Contact info](../assets/android/contact-info.png)

**Contact Settings** controls what this contact may receive from your radio:
battery and basic telemetry, location, environment sensors, and whether they may
run CLI commands on your radio (**Remote CLI**).

![Contact settings](../assets/android/contact-settings.png)

Blocked contacts are listed under **Settings > Blocked**.
