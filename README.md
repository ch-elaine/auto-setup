# personal-automations

A collection of small scripts and workflows I use to automate repetitive tasks in my day-to-day life.

## What's inside

| Automation | Description |
|------------|-------------|
| `example-script` | _Short description of what it does._ |

## Getting started

Clone the repo:

```bash
git clone https://github.com/ch-elaine/personal-automations.git
cd personal-automations
```

Install dependencies (adjust to the tools you actually use):

```bash
pip install -r requirements.txt
```

If an automation needs credentials or API keys, copy the example env file and fill in your own values:

```bash
cp .env.example .env
```

Never commit your `.env` file. It is listed in `.gitignore`.

## Usage

Each automation lives in its own folder with a short note on how to run it. In general:

```bash
python <folder>/main.py
```

To run something on a schedule, use `cron` (macOS/Linux), Task Scheduler (Windows), or a GitHub Actions workflow in `.github/workflows/`.

## Adding a new automation

1. Create a new folder named after the task.
2. Add the script and a short `README.md` explaining what it does and how to run it.
3. Add a row to the table above.

## License

MIT. Feel free to borrow anything useful.
