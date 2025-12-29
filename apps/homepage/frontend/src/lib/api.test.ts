import { describe, it, expect, beforeEach, vi } from 'vitest';
import { getCV, getProjects, getStravaStats } from './api';

// Declare global for TypeScript
declare const global: typeof globalThis;

// Mock fetch with proper typing
const mockFetch = vi.fn();
global.fetch = mockFetch as typeof global.fetch;

describe('API Client', () => {
	beforeEach(() => {
		vi.resetAllMocks();
	});

	describe('getCV', () => {
		it('should fetch CV data successfully', async () => {
			const mockData = {
				name: 'Test User',
				title: 'Developer',
				summary: 'Test summary',
				experience: [],
				education: [],
				skills: []
			};

			mockFetch.mockResolvedValueOnce({
				ok: true,
				json: async () => mockData
			});

			const result = await getCV();
			expect(result).toEqual(mockData);
			expect(global.fetch).toHaveBeenCalledWith('http://localhost:8080/api/cv');
		});

		it('should throw error on failed fetch', async () => {
			mockFetch.mockResolvedValueOnce({
				ok: false,
				status: 500
			});

			await expect(getCV()).rejects.toThrow('Failed to fetch CV');
		});
	});

	describe('getProjects', () => {
		it('should fetch projects successfully', async () => {
			const mockProjects = [
				{
					name: 'test-project',
					description: 'Test',
					url: 'https://github.com/test',
					stars: 10,
					language: 'TypeScript',
					topics: [],
					images: []
				}
			];

			mockFetch.mockResolvedValueOnce({
				ok: true,
				json: async () => mockProjects
			});

			const result = await getProjects();
			expect(result).toEqual(mockProjects);
			expect(global.fetch).toHaveBeenCalledWith('http://localhost:8080/api/projects');
		});

		it('should throw error on failed fetch', async () => {
			mockFetch.mockResolvedValueOnce({
				ok: false
			});

			await expect(getProjects()).rejects.toThrow('Failed to fetch projects');
		});
	});

	describe('getStravaStats', () => {
		it('should fetch Strava stats successfully', async () => {
			const mockStats = {
				total_activities: 42,
				total_distance: 100,
				total_time: 3600,
				recent_runs: []
			};

			mockFetch.mockResolvedValueOnce({
				ok: true,
				json: async () => mockStats
			});

			const result = await getStravaStats();
			expect(result).toEqual(mockStats);
			expect(global.fetch).toHaveBeenCalledWith('http://localhost:8080/api/strava');
		});

		it('should throw error on failed fetch', async () => {
			mockFetch.mockResolvedValueOnce({
				ok: false
			});

			await expect(getStravaStats()).rejects.toThrow('Failed to fetch Strava stats');
		});
	});
});
