"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const YAML = require("yaml");
const expression = (body) => `\${{ ${body} }}`;
test("only protected main proposals and authentic merged drafts reach their own environments", () => {
	const workflow = YAML.parse(
		fs.readFileSync(
			path.resolve(__dirname, "../../.github/workflows/release-please.yml"),
			"utf8",
		),
	);
	assert.deepEqual(workflow.on.push.branches, ["main"]);
	assert.deepEqual(workflow.on.pull_request, {
		branches: ["main"],
		types: ["closed"],
	});
	assert.deepEqual(workflow.permissions, { contents: "read" });
	const { prepare, publish } = workflow.jobs;
	assert.equal(prepare.environment, "release-please");
	assert.match(prepare.if, /pull_request\.merged/);
	assert.match(prepare.if, /head\.repo\.full_name == github\.repository/);
	assert.match(prepare.if, /refs\/heads\/main/);
	for (const step of prepare.steps.filter((step) => step.uses))
		assert.match(step.uses, /@[a-f0-9]{40}$/);
	const doppler = prepare.steps.find((s) => s.id === "credentials");
	assert.equal(
		doppler.with["doppler-token"],
		expression("secrets.DOPPLER_TOKEN"),
	);
	const app = prepare.steps.find((s) => s.id === "app");
	assert.equal(
		app.with["client-id"],
		expression("steps.credentials.outputs.GITHUB_APP_CLIENT_ID"),
	);
	assert.equal(
		app.with["private-key"],
		expression("steps.credentials.outputs.GITHUB_APP_PRIVATE_KEY"),
	);
	const install = prepare.steps.findIndex((s) => s.run?.includes("npm ci"));
	assert.ok(install >= 0 && install < prepare.steps.indexOf(doppler));
	assert.match(prepare.steps[install].run, /--ignore-scripts/);
	assert.deepEqual(publish.permissions, {
		contents: "write",
		actions: "read",
		statuses: "read",
	});
	assert.equal(publish.uses, "./.github/workflows/publish-cpan.yml");
	assert.match(publish.if, /github\.event_name == 'pull_request'/);
	assert.match(publish.if, /needs\.prepare\.outputs\.release_id != ''/);
	for (const name of ["tag", "version", "source_sha", "release_id"]) {
		assert.equal(
			prepare.outputs[name],
			expression(`steps.prepare.outputs.${name}`),
		);
		assert.equal(
			publish.with[name],
			expression(`needs.prepare.outputs.${name}`),
		);
	}
});
