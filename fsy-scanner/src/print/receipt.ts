export function buildReceiptDocument(
  participant: { full_name?: string; room_number?: string | null; table_number?: string | null },
  eventName = 'FSY'
) {
  const name = participant.full_name ?? '(unknown)';
  const room = participant.room_number || '(not assigned)';
  const table = participant.table_number || '(not assigned)';
  const now = new Date().toLocaleString();

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
      content: `Name: ${name}`,
      style: {
        align: 'left',
      },
    },
    {
      type: 'text',
      content: `Room: ${room}`,
      style: {
        align: 'left',
      },
    },
    {
      type: 'text',
      content: `Table: ${table}`,
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
      content: `Checked in: ${now}`,
      style: {
        align: 'left',
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
