export function buildReceiptDocument(
  participant: {
    full_name?: string;
    room_number?: string | null;
    table_number?: string | null;
    tshirt_size?: string | null;
    verified_at?: number | null;
  },
  eventName = 'FSY'
) {
  const name = participant.full_name ?? '(unknown)';
  const room = participant.room_number || '(not assigned)';
  const table = participant.table_number || '(not assigned)';
  const shirt = participant.tshirt_size || '(not assigned)';
  const verifiedAt = participant.verified_at ? new Date(participant.verified_at).toLocaleString() : new Date().toLocaleString();

  return [
    {
      type: 'line',
      style: 'equals',
      widthChars: 32,
    },
    {
      type: 'text',
      content: eventName,
      style: {
        align: 'center',
        size: 3,
        bold: true,
      },
    },
    {
      type: 'text',
      content: 'CHECK-IN RECEIPT',
      style: {
        align: 'center',
        bold: true,
      },
    },
    {
      type: 'line',
      style: 'dashed',
    },
    {
      type: 'text',
      content: `${name}`,
      style: {
        align: 'left',
        bold: true,
      },
    },
    {
      type: 'text',
      content: `Room:   ${room}`,
      style: {
        align: 'left',
      },
    },
    {
      type: 'text',
      content: `Table:  ${table}`,
      style: {
        align: 'left',
      },
    },
    {
      type: 'text',
      content: `Shirt:  ${shirt}`,
      style: {
        align: 'left',
      },
    },
    {
      type: 'line',
      style: 'solid',
    },
    {
      type: 'text',
      content: `Verified: ${verifiedAt}`,
      style: {
        align: 'center',
      },
    },
    {
      type: 'line',
      style: 'solid',
    },
    {
      type: 'text',
      content: 'Welcome to FSY 2026!',
      style: {
        align: 'center',
        bold: true,
      },
    },
    {
      type: 'feed',
      lines: 2,
    },
    {
      type: 'cut',
      partial: true,
    },
  ];
}
