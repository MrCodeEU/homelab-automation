<script lang="ts">
	import { onMount } from 'svelte';
	import { getCV, getProjects, getStravaStats, type CV, type Project, type StravaStats } from '$lib/api';

	let cv: CV | null = null;
	let projects: Project[] = [];
	let strava: StravaStats | null = null;
	let loading = true;
	let error: string | null = null;

	onMount(async () => {
		try {
			[cv, projects, strava] = await Promise.all([
				getCV(),
				getProjects(),
				getStravaStats()
			]);
		} catch (err) {
			error = err instanceof Error ? err.message : 'Failed to load data';
			console.error('Error loading data:', err);
		} finally {
			loading = false;
		}
	});
</script>

<svelte:head>
	<title>Personal Homepage</title>
</svelte:head>

<div class="container">
	{#if loading}
		<div class="loading">
			<div class="spinner"></div>
			<p>Loading...</p>
		</div>
	{:else if error}
		<div class="error">
			<h2>Error</h2>
			<p>{error}</p>
		</div>
	{:else}
		<!-- Hero Section -->
		<section class="hero">
			<h1>{cv?.name || 'Your Name'}</h1>
			<h2>{cv?.title || 'Software Engineer'}</h2>
			<p class="summary">{cv?.summary || 'Building awesome things'}</p>
		</section>

		<!-- Skills Section -->
		<section class="skills">
			<h3>Skills</h3>
			<div class="skill-tags">
				{#each cv?.skills || [] as skill}
					<span class="tag">{skill}</span>
				{/each}
			</div>
		</section>

		<!-- Experience Section -->
		<section class="experience">
			<h3>Experience</h3>
			<div class="timeline">
				{#each cv?.experience || [] as exp}
					<div class="timeline-item">
						<div class="timeline-content">
							<h4>{exp.title}</h4>
							<p class="company">{exp.company} • {exp.location}</p>
							<p class="date">{exp.start_date} - {exp.end_date}</p>
							<p class="description">{exp.description}</p>
						</div>
					</div>
				{/each}
			</div>
		</section>

		<!-- Projects Section -->
		<section class="projects">
			<h3>Projects</h3>
			<div class="project-grid">
				{#each projects as project}
					<div class="project-card">
						{#if project.images && project.images.length > 0}
							<div class="project-image-container">
								<img
									src={project.images[0]}
									alt={project.name}
									class="project-image"
									on:error={(e) => {
										const target = e.currentTarget as HTMLImageElement;
										target.style.display = 'none';
									}}
								/>
								{#if project.featured}
									<span class="featured-badge">Featured</span>
								{/if}
							</div>
						{/if}
						<div class="project-content">
							<h4>
								<a href={project.url} target="_blank" rel="noopener noreferrer">
									{project.name}
								</a>
							</h4>
							<p class="description">{project.description}</p>
							<div class="project-meta">
								<span class="language">{project.language}</span>
								<span class="stars">⭐ {project.stars}</span>
							</div>
							<div class="topics">
								{#each project.topics as topic}
									<span class="topic-tag">{topic}</span>
								{/each}
							</div>
						</div>
					</div>
				{/each}
			</div>
		</section>

		<!-- Strava Section -->
		{#if strava}
			<section class="strava">
				<h3>Running Stats</h3>
				<div class="stats-grid">
					<div class="stat-card">
						<p class="stat-value">{strava.total_activities}</p>
						<p class="stat-label">Total Runs</p>
					</div>
					<div class="stat-card">
						<p class="stat-value">{strava.total_distance.toFixed(1)} km</p>
						<p class="stat-label">Total Distance</p>
					</div>
					<div class="stat-card">
						<p class="stat-value">{Math.floor(strava.total_time / 3600)}h</p>
						<p class="stat-label">Total Time</p>
					</div>
				</div>
				<div class="recent-runs">
					<h4>Recent Runs</h4>
					{#each strava.recent_runs as run}
						<div class="run-item">
							<p class="run-name">{run.name}</p>
							<p class="run-details">
								{run.distance.toFixed(1)} km • {Math.floor(run.moving_time / 60)} min • {run.date}
							</p>
						</div>
					{/each}
				</div>
			</section>
		{/if}
	{/if}
</div>

<style>
	:global(body) {
		margin: 0;
		font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		color: #333;
	}

	.container {
		max-width: 1200px;
		margin: 0 auto;
		padding: 2rem;
	}

	.loading {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		min-height: 100vh;
		color: white;
	}

	.spinner {
		width: 50px;
		height: 50px;
		border: 4px solid rgba(255, 255, 255, 0.3);
		border-top-color: white;
		border-radius: 50%;
		animation: spin 1s linear infinite;
	}

	@keyframes spin {
		to { transform: rotate(360deg); }
	}

	.error {
		background: #fff;
		padding: 2rem;
		border-radius: 8px;
		margin-top: 2rem;
		color: #e53e3e;
	}

	section {
		background: white;
		padding: 2rem;
		margin-bottom: 2rem;
		border-radius: 12px;
		box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
	}

	.hero {
		text-align: center;
		padding: 3rem 2rem;
	}

	.hero h1 {
		font-size: 3rem;
		margin: 0 0 0.5rem 0;
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		-webkit-background-clip: text;
		-webkit-text-fill-color: transparent;
		background-clip: text;
	}

	.hero h2 {
		font-size: 1.5rem;
		color: #666;
		font-weight: normal;
		margin: 0 0 1rem 0;
	}

	.summary {
		font-size: 1.1rem;
		color: #888;
		max-width: 600px;
		margin: 0 auto;
	}

	h3 {
		color: #667eea;
		border-bottom: 2px solid #667eea;
		padding-bottom: 0.5rem;
		margin-bottom: 1.5rem;
	}

	h4 {
		margin: 0 0 0.5rem 0;
		color: #333;
	}

	.skill-tags {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}

	.tag {
		background: #667eea;
		color: white;
		padding: 0.5rem 1rem;
		border-radius: 20px;
		font-size: 0.9rem;
	}

	.timeline {
		position: relative;
		padding-left: 2rem;
	}

	.timeline-item {
		position: relative;
		padding-bottom: 2rem;
	}

	.timeline-item:before {
		content: '';
		position: absolute;
		left: -2rem;
		top: 0;
		width: 12px;
		height: 12px;
		border-radius: 50%;
		background: #667eea;
	}

	.timeline-content {
		padding-left: 1rem;
	}

	.company {
		color: #666;
		font-weight: 500;
		margin: 0.25rem 0;
	}

	.date {
		color: #888;
		font-size: 0.9rem;
		margin: 0.25rem 0;
	}

	.description {
		color: #555;
		line-height: 1.6;
	}

	.project-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
		gap: 1.5rem;
	}

	.project-card {
		border: 1px solid #e2e8f0;
		border-radius: 8px;
		transition: transform 0.2s, box-shadow 0.2s;
		overflow: hidden;
		display: flex;
		flex-direction: column;
	}

	.project-card:hover {
		transform: translateY(-4px);
		box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
	}

	.project-image-container {
		position: relative;
		width: 100%;
		height: 200px;
		overflow: hidden;
		background: #f7fafc;
	}

	.project-image {
		width: 100%;
		height: 100%;
		object-fit: cover;
		transition: transform 0.3s ease;
	}

	.project-card:hover .project-image {
		transform: scale(1.05);
	}

	.featured-badge {
		position: absolute;
		top: 12px;
		right: 12px;
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		color: white;
		padding: 0.4rem 0.8rem;
		border-radius: 20px;
		font-size: 0.75rem;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.5px;
		box-shadow: 0 2px 8px rgba(102, 126, 234, 0.3);
	}

	.project-content {
		padding: 1.5rem;
		flex: 1;
		display: flex;
		flex-direction: column;
	}

	.project-card h4 a {
		color: #667eea;
		text-decoration: none;
	}

	.project-card h4 a:hover {
		text-decoration: underline;
	}

	.project-content .description {
		flex: 1;
		margin-bottom: 1rem;
	}

	.project-meta {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin: 1rem 0;
		font-size: 0.9rem;
		color: #666;
	}

	.topics {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-top: auto;
	}

	.topic-tag {
		background: #f7fafc;
		color: #4a5568;
		padding: 0.25rem 0.75rem;
		border-radius: 12px;
		font-size: 0.8rem;
	}

	.stats-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
		gap: 1rem;
		margin-bottom: 2rem;
	}

	.stat-card {
		text-align: center;
		padding: 1rem;
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		color: white;
		border-radius: 8px;
	}

	.stat-value {
		font-size: 2rem;
		font-weight: bold;
		margin: 0;
	}

	.stat-label {
		margin: 0.5rem 0 0 0;
		opacity: 0.9;
	}

	.recent-runs h4 {
		margin-bottom: 1rem;
	}

	.run-item {
		padding: 1rem;
		border-left: 3px solid #667eea;
		margin-bottom: 1rem;
		background: #f7fafc;
	}

	.run-name {
		font-weight: 500;
		margin: 0 0 0.5rem 0;
	}

	.run-details {
		color: #666;
		font-size: 0.9rem;
		margin: 0;
	}

	@media (max-width: 768px) {
		.hero h1 {
			font-size: 2rem;
		}

		.project-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
