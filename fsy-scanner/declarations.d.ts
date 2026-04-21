declare module 'expo-router';

declare module 'zustand' {
	// Minimal create signature used in this project
	function create<T>(stateCreator: (set: any, get?: any, api?: any) => T): T;
	export default create;
}

declare module '@finan-me/react-native-thermal-printer';
declare module 'react-native-thermal-receipt-printer-image-qr';

// Fallback for other JS-only modules lacking types used in the project
declare module '*';
