# College Football Top 10 Rankings Plugin on TRMNL

<kbd>![usa-college-football-rankings-plugin](https://github.com/user-attachments/assets/5e2fc458-6fea-4c78-b8d2-3731db22b64b)</kbd>

## Step 1: Create a New Private Plugin
Log in to your TRMNL dashboard.
On the left-hand menu, click on the 'Go to Plugins' button.
Find the 'Private Plugin' Plugin to create a Private Plugin.
Click 'Add new' to create a new Private Plugin.

## Step 2: Set up the Polling Strategy
Name your plugin (e.g., "College Football Top 10") then scroll down to the Strategy section.
Choose the Polling strategy from the Strategy dropdown menu.
In the Polling URL field, enter this URL:

```
https://site.api.espn.com/apis/site/v2/sports/football/college-football/rankings
```
Click Save. Once it is saved, the 'Edit Markup' button is not available.

## Step 3: Add the HTML Markup
Click the 'Edit Markup' button.

Copy and paste the following code into the Markup box. This code will display the Top 10 college football teams along with their rank, last week’s rank, and current record.

```
<style>
  .trmnl .table tbody tr {
    height: 38px;
  }
</style>
<div class="view bg-white">
  <div class="layout layout--col gap--space-between">
    <div class="columns">
      <div class="column">
        <table class="table">
          <thead>
            <tr>
              <th><span class="title title--small">Rank</span></th>
              <th><span class="title title--small">Team</span></th>
              <th><span class="title title--small">Last</span></th>
              <th><span class="title title--small">Record</span></th>
            </tr>
          </thead>
          <tbody>
            {% assign counter = 1 %}
            {% for rank in rankings[0].ranks %}
            {% if counter <= 10 %}
              <tr>
                <td><span class="title title--small">{{ counter }}</span></td> <!-- Using counter for the rank -->
                <td>
                  <div class="flex gap gap--small" style="align-items: center">
                    <img style="max-height: 30px" class="image" src="{{ rank.team.logo }}" />
                    <span class="title title--small">{{ rank.team.location }} {{ rank.team.name }}</span>
                  </div>
                </td> <!-- Only using location to avoid duplication -->
                <td><span class="title title--small">{{ rank.previous }}</span></td>
                <td><span class="title title--small">{{ rank.recordSummary }}</span></td>
              </tr>
            {% assign counter = counter | plus: 1 %}
            {% endif %}
            {% endfor %}
          </tbody>
        </table>
      </div>
  </div>
  </div>
  <div class="title_bar">
    <img class="image" src="https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/ESPN-icon-football-college.png&h=160&w=160&scale=crop&cquality=40" />
    <span class="title">College Football</span>
    <span class="instance">Top 10 Rankings</span>
  </div>
</div>
```

## Step 4: Save and Activate the Plugin
Once you have entered the markup, click Save to store the plugin.
Navigate to the Playlists tab in your TRMNL dashboard.
Drag and drop your new College Football Top 10 plugin to the top of your playlist if not automatically added.

## Step 5: View the College Football Rankings on Your Device
Once refreshed, your TRMNL device will display the Top 10 College Football Rankings, showing the team’s current rank, last week’s rank, and win-loss record.

### Customizations (Optional)
Font Size: You can adjust the font size by changing the font-size values in the markup.
More Teams: If you want to display more than 10 teams, you can increase the limit in the code by replacing 10 with the number of teams you want in this line:

```
{% if counter <= 10 %}
```
