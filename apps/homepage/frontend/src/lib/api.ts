const API_BASE = import.meta.env.DEV ? 'http://localhost:8080' : '';

export interface CV {
	name: string;
	title: string;
	summary: string;
	experience: Experience[];
	education: Education[];
	skills: string[];
}

export interface Experience {
	title: string;
	company: string;
	location: string;
	start_date: string;
	end_date: string;
	description: string;
}

export interface Education {
	school: string;
	degree: string;
	field: string;
	start_date: string;
	end_date: string;
}

export interface Project {
	name: string;
	description: string;
	url: string;
	stars: number;
	language: string;
	topics: string[];
	images: string[];
	featured: boolean;
}

export interface StravaStats {
	total_activities: number;
	total_distance: number;
	total_time: number;
	recent_runs: Activity[];
}

export interface Activity {
	name: string;
	distance: number;
	moving_time: number;
	date: string;
}

export async function getCV(): Promise<CV> {
	const res = await fetch(`${API_BASE}/api/cv`);
	if (!res.ok) throw new Error('Failed to fetch CV');
	return res.json();
}

export async function getProjects(): Promise<Project[]> {
	const res = await fetch(`${API_BASE}/api/projects`);
	if (!res.ok) throw new Error('Failed to fetch projects');
	return res.json();
}

export async function getStravaStats(): Promise<StravaStats> {
	const res = await fetch(`${API_BASE}/api/strava`);
	if (!res.ok) throw new Error('Failed to fetch Strava stats');
	return res.json();
}
