.PHONY: lint lint-all template template-all package test help

CHARTS_DIR := charts
CHARTS := $(wildcard $(CHARTS_DIR)/*)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Lint a specific chart (usage: make lint CHART=aegis-agent)
	@if [ -z "$(CHART)" ]; then echo "Usage: make lint CHART=<chart-name>"; exit 1; fi
	helm lint $(CHARTS_DIR)/$(CHART)

lint-all: ## Lint all charts
	@echo "Linting all charts..."
	@if [ -z "$(CHARTS)" ]; then echo "No charts found. Lint passed (empty)."; exit 0; fi
	@failed=0; \
	for chart in $(CHARTS); do \
		echo "--- Linting $$chart ---"; \
		helm lint $$chart || failed=1; \
	done; \
	if [ $$failed -eq 1 ]; then echo "FAILED: Some charts have lint errors"; exit 1; fi
	@echo "All charts passed lint."

template: ## Render templates for a specific chart (usage: make template CHART=aegis-agent ENV=dev)
	@if [ -z "$(CHART)" ]; then echo "Usage: make template CHART=<chart-name> [ENV=dev|qa|prod]"; exit 1; fi
	@if [ -n "$(ENV)" ] && [ -f values/values-$(ENV).yaml ]; then \
		helm template $(CHART) $(CHARTS_DIR)/$(CHART) -f values/values-$(ENV).yaml; \
	else \
		helm template $(CHART) $(CHARTS_DIR)/$(CHART); \
	fi

template-all: ## Render templates for all charts
	@echo "Rendering all chart templates..."
	@if [ -z "$(CHARTS)" ]; then echo "No charts found. Template passed (empty)."; exit 0; fi
	@failed=0; \
	for chart in $(CHARTS); do \
		name=$$(basename $$chart); \
		echo "--- Templating $$name ---"; \
		helm template $$name $$chart || failed=1; \
	done; \
	if [ $$failed -eq 1 ]; then echo "FAILED: Some charts have template errors"; exit 1; fi
	@echo "All charts rendered successfully."

package: ## Package a specific chart (usage: make package CHART=aegis-agent)
	@if [ -z "$(CHART)" ]; then echo "Usage: make package CHART=<chart-name>"; exit 1; fi
	helm package $(CHARTS_DIR)/$(CHART)

package-all: ## Package all charts
	@echo "Packaging all charts..."
	@for chart in $(CHARTS); do \
		echo "--- Packaging $$chart ---"; \
		helm package $$chart; \
	done

test: ## Run helm-unittest for all charts
	@echo "Running unit tests..."
	@if [ -z "$(CHARTS)" ]; then echo "No charts found. Tests passed (empty)."; exit 0; fi
	@failed=0; \
	for chart in $(CHARTS); do \
		if [ -d "$$chart/tests" ]; then \
			echo "--- Testing $$chart ---"; \
			helm unittest $$chart || failed=1; \
		fi; \
	done; \
	if [ $$failed -eq 1 ]; then echo "FAILED: Some tests failed"; exit 1; fi
	@echo "All tests passed."

yamllint: ## Run yamllint on all YAML files
	@echo "Running yamllint..."
	yamllint -c .yamllint.yml charts/ values/
