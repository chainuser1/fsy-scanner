// Receipt builder scaffold
export function buildReceipt(participant: { full_name?: string; room_number?: string; table_number?: string }, eventName = 'FSY'): string {
  const name = participant.full_name ?? '(unknown)';
  const room = participant.room_number || '(not assigned)';
  const table = participant.table_number || '(not assigned)';
  const now = new Date().toISOString();

  return `================================\n      ${eventName}\n      CHECK-IN RECEIPT\n================================\nName:  ${name}\nRoom:  ${room}\nTable: ${table}\n================================\nChecked in: ${now}\n================================\n    Welcome to ${eventName}!\n================================\n`;
}
